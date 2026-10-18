class EgressGateTest < AcceptanceTest
  test "the real filtering proxy forwards allowed plain HTTP to its destination" do
    upstream = fake_upstream body: "package metadata"
    start_filter allow: ["127.0.0.1"]

    assert_filter_http upstream.url + "/packages", status: 200, body: "package metadata"

    assert_equal "/packages", upstream.requests.last&.fetch("path")
  end

  test "plain HTTP forwarding preserves a POST method and its complete request body" do
    upstream = fake_upstream
    start_filter allow: ["127.0.0.1"]

    assert_filter_http upstream.url + "/publish", status: 200, method: "POST", request_body: "package=sample&version=2"

    assert_equal "POST", upstream.requests.last&.fetch("method")
    assert_equal "package=sample&version=2", upstream.requests.last&.fetch("body")
  end

  test "real denial logs omit URL paths query secrets and authorization headers" do
    start_filter

    assert_filter_http "http://example.com/private-path?token=secret-query", status: 403, headers: { "Authorization" => "Bearer secret-header" }

    assert_filter_denial "example.com", port: 80
    assert_filter_log_omits "private-path", "secret-query", "secret-header"
  end

  test "the real filtering proxy tunnels arbitrary bytes after an allowed CONNECT without inspecting TLS" do
    destination = echo_destination
    start_filter allow: [destination]

    assert_filter_tunnel destination, bytes: "\x16\x03\x01opaque-client-bytes"
  end

  test "the real filtering proxy rejects an unlisted host before DNS and records host port and trusted container" do
    start_filter allow: ["registry.npmjs.org"]

    assert_filter_http "http://example.com/private?secret=hidden", status: 403, body: "example.com"

    assert_filter_denial "example.com", port: 80
    assert_filter_count "shop", 1
  end

  test "an allowed hostname with an explicit port does not allow its other ports" do
    start_filter allow: ["example.com:443"]

    assert_filter_http "http://example.com/", status: 403, body: "example.com"

    assert_filter_denial "example.com", port: 80
  end

  test "an unlisted CONNECT destination is denied and never reaches the upstream proxy" do
    proxy = fake_proxy status: 200
    start_filter allow: ["api.anthropic.com:443"], upstream: proxy.url

    assert_filter_connect_denied "example.com:443"

    assert_filter_denial "example.com", port: 443
    assert_empty proxy.targets, "Expected the unlisted CONNECT to be refused before forwarding."
  end

  ["badexample.com", "example.com", "api.example.com.evil.test"].each do |host|
    test "a wildcard for subdomains of example.com does not allow #{host}" do
      start_filter allow: ["*.example.com"]

      assert_filter_http "http://#{host}/", status: 403, body: host
    end
  end

  test "a wildcard matches complete subdomain labels and ignores case and a final dot" do
    proxy = fake_proxy status: 200
    start_filter allow: ["*.example.com:80"], upstream: proxy.url

    assert_filter_http "http://Deep.API.Example.COM./", status: 200
  end

  test "an incompatible HTTP Host header cannot select a different allowed authority" do
    start_filter allow: ["registry.npmjs.org"]

    assert_filter_http "http://example.com/", status: 400, headers: { "Host" => "registry.npmjs.org" }
  end

  test "an unrecognized peer cannot claim another container's policy with an HTTP header" do
    start_filter allow: ["example.com"], addresses: ["127.0.0.2"]

    assert_filter_http "http://example.com/", status: 403, headers: { "X-Farmy-Container" => "shop" }

    assert_filter_denial "example.com", port: 80, container: "unknown", service: "unknown"
  end

  test "the real proxy applies a valid reload to the next request and preserves its denial count" do
    upstream = fake_upstream body: "newly allowed"
    start_filter
    assert_filter_http upstream.url, status: 403

    reload_filter allow: ["127.0.0.1"]

    assert_filter_http upstream.url, status: 200, body: "newly allowed"
    assert_filter_count "shop", 1
  end

  test "a malformed reload refuses with a reason and leaves the prior policy active" do
    upstream = fake_upstream
    start_filter allow: ["127.0.0.1"]

    reject_filter_reload '{"version":99,"clients":{}}'

    assert_filter_http upstream.url, status: 200, body: "ok"
  end

  test "allowed plain HTTP goes through the configured upstream proxy" do
    upstream = fake_upstream
    proxy = fake_proxy
    start_filter allow: ["127.0.0.1"], upstream: proxy.url

    assert_filter_http upstream.url + "/through-proxy", status: 200, body: "ok"

    assert_equal 1, proxy.targets.size, "Expected the configured upstream proxy to receive the allowed request."
  end

  test "allowed CONNECT goes through the configured upstream proxy as an opaque tunnel" do
    destination = echo_destination
    proxy = fake_proxy
    start_filter allow: [destination], upstream: proxy.url

    assert_filter_tunnel destination, bytes: "encrypted application bytes"

    assert_equal 1, proxy.targets.size, "Expected the configured upstream proxy to receive CONNECT."
  end

  test "a failed upstream proxy returns 502 without retrying the allowed destination directly" do
    upstream = fake_upstream
    proxy = fake_proxy status: 502
    start_filter allow: ["127.0.0.1"], upstream: proxy.url

    assert_filter_http upstream.url, status: 502

    assert_empty upstream.requests, "Expected no direct fallback when the configured upstream fails."
  end
end
