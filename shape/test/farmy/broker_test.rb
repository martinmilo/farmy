class BrokerTest < AcceptanceTest
  # bin/farmy-keys as a program, against a fake upstream of the test's own.

test "the broker with no routes starts, answers health and listens on the socket it is given" do
  start_broker routes: {}

  response = through_broker "/-/health"

  assert_equal "200", response.code
  assert_broker_socket
end

  test "a request through a route reaches the upstream with the secret in the auth header" do
    upstream = fake_upstream
    start_broker routes: { "git" => "#{upstream.url} basic x-access-token GIT_TOKEN" }
    load_broker "GIT_TOKEN" => "frg_9c1e5d7b2a"

    response = through_broker "/git/acme/shop.git/info/refs?service=git-upload-pack"

    assert_equal "200", response.code
    assert_equal "/acme/shop.git/info/refs?service=git-upload-pack", upstream.requests.last["path"]
    assert_equal "Basic #{["x-access-token:frg_9c1e5d7b2a"].pack("m0")}", upstream.requests.last["headers"]["authorization"]
  end

  test "the client's own authorization header does not reach the upstream" do
    upstream = fake_upstream
    start_broker routes: { "anthropic" => "#{upstream.url} header x-api-key ANTHROPIC_API_KEY" }
    load_broker "ANTHROPIC_API_KEY" => "sk-ant-7f3a9c"

    through_broker "/anthropic/v1/messages", headers: { "Authorization" => "Bearer stolen", "x-api-key" => "guess" }

    assert_equal "sk-ant-7f3a9c", upstream.requests.last["headers"]["x-api-key"]
    assert_nil upstream.requests.last["headers"]["authorization"]
  end

  test "a route that was never loaded answers 503 and names the route" do
    upstream = fake_upstream
    start_broker routes: { "anthropic" => "#{upstream.url} header x-api-key ANTHROPIC_API_KEY" }

    response = through_broker "/anthropic/v1/messages"

    assert_equal "503", response.code
    assert_includes response.body, "anthropic"
    assert_empty upstream.requests
  end

  test "a path outside the configured routes answers 404" do
    upstream = fake_upstream
    start_broker routes: { "git" => "#{upstream.url} basic x-access-token GIT_TOKEN" }
    load_broker "GIT_TOKEN" => "frg_9c1e5d7b2a"

    response = through_broker "/github/acme/shop.git/info/refs"

    assert_equal "404", response.code
    assert_empty upstream.requests
  end

  test "a redirect from the upstream is rewritten to stay on the route" do
    upstream = fake_upstream status: 302, headers: { "Location" => "{origin}/acme/shop-renamed.git/info/refs" }
    start_broker routes: { "git" => "#{upstream.url} basic x-access-token GIT_TOKEN" }
    load_broker "GIT_TOKEN" => "frg_9c1e5d7b2a"

    response = through_broker "/git/acme/shop.git/info/refs"

    assert_equal "302", response.code
    assert_match %r{\Ahttp://127\.0\.0\.1:\d+/git/acme/shop-renamed\.git/info/refs\z}, response["Location"]
  end

  test "the loading socket is not reachable through the proxy port" do
    upstream = fake_upstream
    start_broker routes: { "git" => "#{upstream.url} basic x-access-token GIT_TOKEN" }

    response = through_broker "/load", method: :post

    assert_equal "404", response.code
    assert_equal "200", through_broker("/-/health").code
  end
  test "a key loaded for an SSH route is served by the broker's agent" do
    start_broker routes: { "git" => "- ssh - GIT_SSH_KEY" }
    load_broker "GIT_SSH_KEY" => fixture("keys/git_ed25519")

    assert_includes agent_identities, "farmy-test-key"
  end
  %w[TERM INT].each do |signal|
    test "a broker stopped with #{signal} ends its SSH agent with it" do
      start_broker routes: { "git" => "- ssh - GIT_SSH_KEY" }
      load_broker "GIT_SSH_KEY" => fixture("keys/git_ed25519")
      assert_includes agent_identities, "farmy-test-key"

      stop_broker signal

      assert_broker_left_nothing_running
    end
  end
  test "the SSH agent does not outlive a broker killed with KILL" do
    start_broker routes: { "git" => "- ssh - GIT_SSH_KEY" }
    load_broker "GIT_SSH_KEY" => fixture("keys/git_ed25519")
    assert_includes agent_identities, "farmy-test-key"

    stop_broker "KILL"

    assert_broker_left_nothing_running
  end
  test "a broker whose parent goes away ends, and its SSH agent with it" do
    start_broker_under_parent routes: { "git" => "- ssh - GIT_SSH_KEY" }
    load_broker "GIT_SSH_KEY" => fixture("keys/git_ed25519")
    assert_includes agent_identities, "farmy-test-key"

    end_broker_parent

    assert_broker_left_nothing_running
  end
  test "a load without a secret unloads it and the route answers 503 again" do
    upstream = fake_upstream
    start_broker routes: { "anthropic" => "#{upstream.url} header x-api-key ANTHROPIC_API_KEY" }
    load_broker "ANTHROPIC_API_KEY" => "sk-ant-7f3a9c"
    assert_equal "200", through_broker("/anthropic/v1/messages").code

    load_broker({})

    response = through_broker "/anthropic/v1/messages"
    assert_equal "503", response.code
    assert_equal 1, upstream.requests.size
  end
test "with HTTP_PROXY set the broker sends its upstream requests through the proxy" do
  upstream = fake_upstream
  proxy = fake_proxy
  start_broker routes: { "git" => "#{upstream.url} basic x-access-token GIT_TOKEN" }, env: { "HTTP_PROXY" => proxy.url, "HTTPS_PROXY" => proxy.url, "NO_PROXY" => "" }
  load_broker "GIT_TOKEN" => "frg_9c1e5d7b2a"

  response = through_broker "/git/acme/shop.git/info/refs"

  assert_equal "200", response.code
  assert_equal ["#{upstream.url}/acme/shop.git/info/refs"], proxy.targets
  assert_equal "/acme/shop.git/info/refs", upstream.requests.last["path"]
end

  test "farmy-keys loaded lists the secrets the broker holds" do
    start_broker routes: { "git" => "https://github.com basic x-access-token GIT_TOKEN" }
    load_broker "GIT_TOKEN" => "frg_9c1e5d7b2a"

    assert_equal ["GIT_TOKEN"], broker_loaded
  end

  test "a base64-encoded key for an SSH route is refused with an error that says it looks base64-encoded" do
    start_broker routes: { "git" => "- ssh - GIT_SSH_KEY" }

    out, code = load_broker_answer("GIT_SSH_KEY" => [fixture("keys/git_ed25519")].pack("m0"))

    assert_equal 1, code, "Expected farmy-keys load to fail (exit 1) when the agent refuses the key.\n#{out}"
    assert_includes out, "base64"
    assert_empty broker_loaded
  end

  test "a public git route forwards a request without credentials while its secret is not loaded" do
    upstream = fake_upstream
    start_broker routes: { "git" => "#{upstream.url} basic x-access-token GIT_TOKEN public" }

    response = through_broker "/git/acme/shop.git/info/refs", headers: { "Authorization" => "Basic Y2xpZW50OnNlY3JldA==" }

    assert_equal "200", response.code
    assert_equal "/acme/shop.git/info/refs", upstream.requests.last["path"]
    assert_nil upstream.requests.last["headers"]["authorization"]
  end

  test "a public git route adds its secret once it is loaded" do
    upstream = fake_upstream
    start_broker routes: { "git" => "#{upstream.url} basic x-access-token GIT_TOKEN public" }
    load_broker "GIT_TOKEN" => "frg_9c1e5d7b2a"

    through_broker "/git/acme/shop.git/info/refs"

    assert_equal "Basic eC1hY2Nlc3MtdG9rZW46ZnJnXzljMWU1ZDdiMmE=", upstream.requests.last["headers"]["authorization"] # x-access-token:frg_9c1e5d7b2a
  end
end
