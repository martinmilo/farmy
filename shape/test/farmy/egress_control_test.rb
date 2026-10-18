class EgressControlTest < AcceptanceTest
  def setup = workspace("workshop")

  test "global restriction puts an app only on internal networks without creating a mesh" do
    egress_apps

    farmy "start", "shop"

    assert_success
    assert_internal_only "shop"
    refute_container "farmy-egress"
  end

  test "a service can opt into restriction while global restriction is off" do
    egress_apps global: false, shop: true

    farmy "start", "shop"

    assert_success
    assert_internal_only "shop"
  end

  test "a service cannot opt out of global restriction with restrict false" do
    egress_apps shop: false

    farmy "start", "shop"

    assert_success
    assert_internal_only "shop"
  end

  test "an unrestricted app keeps its direct route and has no filtering proxy" do
    egress_apps global: false
    farmy "start", "shop"

    app_curl "https://example.com/"

    assert_success
    assert_no_filtering_gate
  end

  ["https://registry.npmjs.org/", "http://deb.debian.org/debian/"].each do |url|
    test "a restricted app reaches #{url} through its filtering gate" do
      egress_apps
      farmy "start", "shop"

      app_curl url

      assert_success
      assert_stdout "ok"
      assert_internal_only "shop"
    end
  end

  test "ignoring the proxy leaves a restricted app with no direct route even to an allowed host" do
    egress_apps
    farmy "start", "shop"

    app_curl "https://registry.npmjs.org/", direct: true

    assert_failure
    assert_stderr "no route out"
  end

  test "an unlisted host is denied with host port and container in egress log" do
    egress_apps
    farmy "start", "shop"
    app_curl "https://example.com/private?token=not-for-logs"
    assert_failure
    assert_stderr "denied example.com:443"

    farmy "egress", "log", "shop"

    assert_success
    assert_stdout(/example\.com.*443.*shop|shop.*example\.com.*443/)
    refute_stdout "not-for-logs"
  end

  test "the app gate combines enabled agent git registry global and service destinations" do
    egress_apps agents: ["claude"], allow: ["docs.example.com"], service_allow: ["workspace.example.com"], definition_allow: ["definition.example.com"]
    git_egress_routes
    farmy "start", "shop", stdin: "GIT_TOKEN=git-test-token\nOTHER_TOKEN=other-test-token\n"

    app_curl "https://api.anthropic.com/"

    assert_success
    assert_filtered_request "api.anthropic.com"
  end

  {
    "https://code.example.com:8443/acme/shop.git" => ["code.example.com", 8443],
    "https://registry.npmjs.org/" => ["registry.npmjs.org", 443],
    "https://docs.example.com/" => ["docs.example.com", 443],
    "https://workspace.example.com/" => ["workspace.example.com", 443],
    "https://definition.example.com/" => ["definition.example.com", 443]
  }.each do |url, (host, port)|
    test "app policy includes #{host}:#{port} from its configured data" do
      egress_apps allow: ["docs.example.com"], service_allow: ["workspace.example.com"], definition_allow: ["definition.example.com"]
      git_egress_routes
      farmy "start", "shop", stdin: "GIT_TOKEN=git-test-token\nOTHER_TOKEN=other-test-token\n"

      app_curl url

      assert_success
      assert_filtered_request host, port: port
    end
  end

  ["api.openai.com", "other.example.com", "badregistry.npmjs.org"].each do |host|
    test "app policy denies #{host} because disabled agents non-git routes and suffix lookalikes grant nothing" do
      egress_apps agents: ["claude"]
      git_egress_routes
      farmy "start", "shop", stdin: "GIT_TOKEN=git-test-token\nOTHER_TOKEN=other-test-token\n"

      app_curl "https://#{host}/"

      assert_failure
      assert_stderr "denied #{host}:443"
    end
  end

  test "a git route with explicit port does not grant another port on that host" do
    egress_apps
    git_egress_routes
    farmy "start", "shop", stdin: "GIT_TOKEN=git-test-token\nOTHER_TOKEN=other-test-token\n"

    app_curl "https://code.example.com/"

    assert_failure
    assert_stderr "denied code.example.com:443"
  end

  test "a custom catalogue agent contributes its api_hosts without vendor code" do
    egress_apps agents: { "mytool" => { "install" => nil, "login" => nil, "api_hosts" => ["api.mytool.example:443"] } }
    farmy "start", "shop"

    app_curl "https://api.mytool.example/"

    assert_success
    assert_filtered_request "api.mytool.example"
  end

  test "an api_hosts override replaces the shipped agent's destinations" do
    egress_apps agents: { "claude" => { "api_hosts" => ["api.custom.example:443"] } }
    farmy "start", "shop"
    app_curl "https://api.custom.example/"
    assert_success

    app_curl "https://api.anthropic.com/"

    assert_failure
    assert_stderr "denied api.anthropic.com:443"
  end

  test "with mesh egress the filtering gate forwards to farmy-egress and the app cannot bypass it" do
    egress_apps mesh: true
    farmy "start", "shop", stdin: "TS_AUTHKEY=tskey-auth-example\n"
    app_curl "https://registry.npmjs.org/"
    assert_success
    assert_filtered_request "registry.npmjs.org", upstream: "farmy-egress"

    app_curl "https://example.com/", proxy: "http://farmy-egress:1055"

    assert_failure
    assert_stderr "no route to proxy farmy-egress"
  end

  test "with a configured upstream the app still uses a filtering gate which forwards allowed traffic" do
    egress_apps upstream: "http://proxy.example.com:3128"
    farmy "start", "shop"

    app_curl "https://registry.npmjs.org/"

    assert_success
    assert_filtered_request "registry.npmjs.org", upstream: "proxy.example.com"
    assert_internal_only "shop"
  end

  test "egress allow persists a global addition and changes the next request without restarting containers" do
    egress_apps
    farmy "start", "shop"
    app_curl "https://docs.example.com/"
    assert_failure
    remember_container_starts

    farmy "egress", "allow", "docs.example.com"

    assert_success
    assert_saved_allow "docs.example.com"
    assert_no_container_restarted
    app_curl "https://docs.example.com/"
    assert_success
  end

  test "a service-only live addition grants shop the host while notes still gets a denial" do
    egress_apps
    farmy "start", "shop"
    farmy "start", "notes"
    remember_container_starts

    farmy "egress", "allow", "private.example.com", "--service", "shop"

    assert_success
    assert_saved_allow "private.example.com", service: "shop"
    assert_no_container_restarted
    app_curl "https://private.example.com/"
    assert_success
    app_curl "https://private.example.com/", service: "notes"
    assert_failure
    assert_stderr "denied private.example.com:443"
  end

  test "adding a duplicate allowed host is idempotent and preserves the running containers" do
    egress_apps allow: ["docs.example.com"]
    farmy "start", "shop"
    remember_container_starts

    farmy "egress", "allow", "DOCS.EXAMPLE.COM."

    assert_success
    assert_saved_allow "docs.example.com"
    assert_no_container_restarted
  end

  ["https://docs.example.com/path", "*.com:*", "docs.example.com:65536"].each do |host|
    test "egress allow refuses invalid destination #{host} without changing configuration" do
      egress_apps

      farmy "egress", "allow", host

      assert_exit 1
      assert_stderr(/host|destination|port/i)
      assert_unchanged "farmy.yml"
    end
  end

  test "egress allow refuses an unknown service without changing configuration" do
    egress_apps

    farmy "egress", "allow", "docs.example.com", "--service", "missing"

    assert_exit 1
    assert_stderr "missing"
    assert_unchanged "farmy.yml"
  end

  test "egress log service selection excludes another service's denials" do
    egress_apps
    farmy "start", "shop"
    farmy "start", "notes"
    app_curl "https://blocked-shop.example.com/"
    app_curl "https://blocked-notes.example.com/", service: "notes"

    farmy "egress", "log", "shop"

    assert_success
    assert_stdout "blocked-shop.example.com"
    refute_stdout "blocked-notes.example.com"
  end

  test "status exposes each service's denial count and reload does not reset it" do
    egress_apps
    farmy "start", "shop"
    app_curl "https://example.com/"
    app_curl "https://example.com/"
    farmy "egress", "allow", "docs.example.com"

    farmy "status", "--json"

    assert_success
    assert_egress_status "shop", restricted: true, denied: 2
  end

  test "egress log with no requests reports an empty result successfully" do
    egress_apps
    farmy "start", "shop"

    farmy "egress", "log"

    assert_success
    assert_stdout(/no.*egress.*events/i)
  end
end
