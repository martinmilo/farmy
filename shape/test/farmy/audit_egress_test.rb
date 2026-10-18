class AuditEgressTest < AcceptanceTest
  def setup = workspace("workshop")

  test "global audit permits an unlisted host through the gate on internal networks" do
    egress_apps global: "audit"
    farmy "start", "shop"

    app_curl "https://example.com/"

    assert_success
    assert_internal_only "shop"
    assert_filtered_request "example.com"
  end

  test "ignoring the proxy in audit still leaves the container without a route out" do
    egress_apps global: "audit"
    farmy "start", "shop"

    app_curl "https://example.com/", direct: true

    assert_failure
    assert_stderr "no route out"
  end

  test "a service may select audit under its nested egress settings" do
    egress_apps global: false
    nested_restriction "audit"
    farmy "start", "shop"

    app_curl "https://example.com/"

    assert_success
    assert_filtered_request "example.com"
  end

  [[true, "audit"], ["audit", true]].each do |global, service|
    test "global #{global} and service #{service} preserve the stronger enforce restriction" do
      egress_apps global: global, shop: service
      farmy "start", "shop"

      app_curl "https://example.com/"

      assert_failure
      assert_stderr "denied example.com:443"
    end
  end

  test "a service false setting cannot turn global audit into a direct outward network" do
    egress_apps global: "audit", shop: false
    farmy "start", "shop"

    app_curl "https://example.com/"

    assert_success
    assert_internal_only "shop"
    assert_filtered_request "example.com"
  end

  test "audit records each destination once despite repeated requests and a policy reload" do
    egress_apps global: "audit"
    farmy "start", "shop"
    app_curl "https://example.com/first?secret=hidden"
    farmy "egress", "allow", "docs.example.com"
    app_curl "https://EXAMPLE.COM./second"

    farmy "egress", "log", "shop", "--json"

    assert_success
    assert_egress_events 1, event: "allowed", host: "example.com", container: "shop"
    refute_stdout "hidden"
  end

  test "audit treats another port as a new destination" do
    egress_apps global: "audit"
    farmy "start", "shop"
    app_curl "https://example.com/"
    app_curl "http://example.com/"

    farmy "egress", "log", "shop", "--json"

    assert_egress_events 2, event: "allowed", host: "example.com"
  end

  test "audit observes the same destination separately for two containers" do
    egress_apps global: "audit"
    farmy "start", "shop"
    farmy "start", "notes"
    app_curl "https://example.com/"
    app_curl "https://example.com/", service: "notes"

    farmy "egress", "log", "--json"

    assert_egress_events 1, event: "allowed", host: "example.com", container: "shop"
    assert_egress_events 1, event: "allowed", host: "example.com", container: "notes"
  end

  test "audit logs allowlisted destinations as well as newly discovered hosts" do
    egress_apps global: "audit"
    farmy "start", "shop"
    app_curl "https://registry.npmjs.org/"

    farmy "egress", "log", "shop", "--json"

    assert_egress_events 1, event: "allowed", host: "registry.npmjs.org"
  end

  test "audit status identifies the mode and does not count observations as denials" do
    egress_apps global: "audit"
    farmy "start", "shop"
    app_curl "https://example.com/"

    farmy "status", "--json"

    assert_egress_status "shop", restricted: true, denied: 0, mode: "audit"
  end

  test "audit keeps using the configured upstream instead of connecting around it" do
    egress_apps global: "audit", upstream: "http://proxy.example.com:3128"
    farmy "start", "shop"

    app_curl "https://example.com/"

    assert_success
    assert_filtered_request "example.com", upstream: "proxy.example.com"
  end

  test "egress log defaults to readable denial lines with time identity destination and decision" do
    egress_apps
    farmy "start", "shop"
    app_curl "https://example.com/"

    farmy "egress", "log", "shop"

    assert_success
    assert_readable_event host: "example.com:443", decision: "denied"
  end

  test "readable egress log also displays allowed audit observations" do
    egress_apps global: "audit"
    farmy "start", "shop"
    app_curl "https://example.com/"

    farmy "egress", "log", "shop"

    assert_readable_event host: "example.com:443", decision: "allowed"
  end

  test "egress log json preserves structured denials with timestamps" do
    egress_apps
    farmy "start", "shop"
    app_curl "https://example.com/"

    farmy "egress", "log", "shop", "--json"

    assert_egress_events 1, event: "denied", host: "example.com", container: "shop"
  end

  test "empty json egress history contains no prose or JSON placeholder" do
    egress_apps
    farmy "start", "shop"

    farmy "egress", "log", "--json"

    assert_success
    assert_stdout_is ""
  end

  test "factory agents ignore global audit and still deny every non-API destination" do
    factory_service model: :token, extra_config: "egress:\n  restrict: audit\n"
    nested_restriction "audit"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" }, requests: [{ url: "https://example.com/" }] })

    factory_start

    assert_success
    assert_filtered_request "example.com", status: 403, container: /shop-run-.*-agent-/
    assert_agents_filtered
  end
end

class AuditProxyTest < AcceptanceTest
  test "the real gate permits an unlisted HTTP destination in audit and emits one observation across reload" do
    upstream = fake_upstream
    start_filter mode: "audit"
    assert_filter_http upstream.url + "/one", status: 200
    reload_filter allow: []

    assert_filter_http upstream.url + "/two", status: 200

    assert_filter_observations 1, host: "127.0.0.1"
  end

  test "the real audit gate permits an unlisted CONNECT as an opaque tunnel" do
    destination = echo_destination
    start_filter mode: "audit"

    assert_filter_tunnel destination, bytes: "opaque audit connection"

    assert_filter_observations 1, host: "127.0.0.1"
  end

  test "an unknown peer cannot use audit to bypass container identity" do
    start_filter mode: "audit", addresses: ["127.0.0.2"]

    assert_filter_http "http://example.com/", status: 403, headers: { "X-Farmy-Container" => "shop" }

    assert_filter_denial "example.com", port: 80, container: "unknown", service: "unknown"
  end

  test "real audit observations omit request paths queries and authorization credentials" do
    upstream = fake_upstream
    start_filter mode: "audit"

    assert_filter_http upstream.url + "/private-path?token=secret-query", status: 200, headers: { "Authorization" => "Bearer secret-header" }

    assert_filter_observations 1, host: "127.0.0.1"
    assert_filter_log_omits "private-path", "secret-query", "secret-header"
  end
end
