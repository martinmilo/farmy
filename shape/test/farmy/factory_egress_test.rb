class FactoryEgressTest < AcceptanceTest
  def setup = workspace("workshop")

  [:token, :api].each do |mode|
    test "a factory agent in #{mode} mode reaches its API host through a gate on internal networks only" do
      factory_service model: mode
      agent_plays({ writes: { "src/app.txt" => "fixed\n" }, requests: [{ url: "https://api.anthropic.com/v1/messages" }] })

      factory_start

      assert_success
      assert_agents_filtered
      assert_filtered_request "api.anthropic.com", container: /shop-run-.*-agent-/
      assert_no_run_filtering_resources
    end
  end

  ["registry.npmjs.org", "github.com", "api.openai.com", "app-only.example.com"].each do |host|
    test "factory agent policy denies #{host} even when app policy would allow it" do
      factory_service model: :token, extra_config: "agents: [claude, codex]\negress:\n  allow: [app-only.example.com, github.com]\n"
      agent_plays({ writes: { "src/app.txt" => "fixed\n" }, requests: [{ url: "https://#{host}/" }] })

      factory_start

      assert_success
      assert_filtered_request host, status: 403, container: /shop-run-.*-agent-/
    end
  end

  test "factory denials remain visible after its filtering resources are removed" do
    factory_service model: :token
    agent_plays({ writes: { "src/app.txt" => "fixed\n" }, requests: [{ url: "https://example.com/" }] })
    factory_start
    assert_success

    farmy "egress", "log", "shop"

    assert_success
    assert_stdout "example.com"
    assert_stdout(/shop-run-.*-agent-/)
    assert_no_run_filtering_resources
  end

  test "a factory agent ignoring its proxy cannot reach even its allowed API host directly" do
    factory_service model: :token
    agent_plays({ writes: { "src/app.txt" => "fixed\n" }, requests: [{ url: "https://api.anthropic.com/", direct: true }] })

    factory_start

    assert_success
    assert_direct_request_blocked "api.anthropic.com", container: /shop-run-.*-agent-/
  end

  test "the default red-first prompt requires every failing check to make the test fail" do
    profiled_factory
    agent_plays({ writes: { "test/check.sh" => "set -e\ngrep -q ready src/app.txt\ngrep -q fixed src/app.txt\n" } })

    factory_start profile: "shape"

    assert_exit 2
    assert_stdout "awaiting_review"
    assert_last_agent_prompt "any", "check", "set -e", "assertion"
  end
end
