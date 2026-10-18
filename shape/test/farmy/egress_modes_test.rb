class EgressModesTest < AcceptanceTest
  def setup = workspace("workshop")

  ["workspace egress.restrict", "service restrict", "service egress.restrict"].each do |location|
    { "off" => false, "audit" => true, "enforce" => true }.each do |mode, restricted|
      test "#{location} accepts #{mode} and public status uses the same canonical mode" do
        egress_mode mode, at: location
        farmy "start", "shop"
        assert_success

        farmy "status", "--json"

        assert_success
        assert_egress_status "shop", restricted: restricted, denied: 0, mode: mode
      end
    end
  end

  { true => "enforce", false => "off" }.each do |value, mode|
    test "legacy restrict #{value} remains accepted and public status reports #{mode}" do
      egress_apps global: value
      farmy "start", "shop"
      assert_success

      farmy "status", "--json"

      assert_success
      assert_egress_status "shop", restricted: value, denied: 0, mode: mode
    end
  end

  test "off keeps an app's direct outward route and creates no filtering gate" do
    egress_apps global: "off"
    farmy "start", "shop"
    assert_success

    app_curl "https://example.com/", direct: true

    assert_success
    assert_no_filtering_gate
  end

  [["enforce", "audit"], ["audit", "enforce"], ["enforce", "off"], ["off", "enforce"]].each do |global, service|
    test "global #{global} and service #{service} retain enforce as the stronger restriction" do
      egress_apps global: global, shop: service
      farmy "start", "shop"
      assert_success

      app_curl "https://example.com/"

      assert_failure
      assert_stderr "denied example.com:443"
      assert_internal_only "shop"
    end
  end

  ["audit", "enforce"].each do |mode|
    test "#{mode} keeps the app without a direct route for traffic that ignores HTTP and CONNECT proxies" do
      egress_apps global: mode
      farmy "start", "shop"
      assert_success

      app_curl "https://registry.npmjs.org/", direct: true

      assert_failure
      assert_stderr "no route out"
      assert_internal_only "shop"
    end
  end

  test "factory agents retain enforced API-only egress when interactive apps select off" do
    factory_service model: :token, extra_config: "egress:\n  restrict: off\n"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" }, requests: [{ url: "https://example.com/" }] })

    factory_start

    assert_success
    assert_filtered_request "example.com", status: 403, container: /shop-run-.*-agent-/
    assert_agents_filtered
  end

  test "the egress guide covers HTTP opaque CONNECT no independent route for other protocols and excluded image builds" do
    assert_egress_coverage_documented
  end
end
