# What the fake Docker cannot show about agent installs: a real build on a Debian slim image. Skipped wherever
# no real Docker answers (REQUIRE_DOCKER=1 makes that a failure); on a machine with Docker:
# REQUIRE_DOCKER=1 TEST_COMMAND_TIMEOUT=1800 JOBS=1 bin/verify --all -n /AgentCliIntegration/
class AgentCliIntegrationTest < AcceptanceTest
  def setup
    require_real_docker
    workspace "workshop"
    write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\n"
  end

  def teardown = (script "farmy", "destroy", "shop", stdin: "y\n" if real_docker_test?) # its volumes too; its containers go anyway

  # catalogue agent → its CLI and version line
  { "claude" => ["claude", "claude --version"], "codex" => ["codex", "codex --version"], "gemini" => ["gemini", "gemini --version"],
    "opencode" => ["opencode", "opencode --version"], "cursor" => ["agent", "agent --version"], "copilot" => ["copilot", "copilot --version"] }.each do |agent, (cli, version)|
    test "in a real Debian app image the catalogue's #{agent} CLI answers #{version} as dev and lives outside every home directory" do
      write_file "farmy.yml", "agents:\n  #{agent}: {}\n"

      script "farmy", "start", "shop"

      assert_success
      assert_runs_as_dev "shop", version
      assert_outside_homes "shop", cli
    end
  end

  test "a toolbox build whose agent CLI dev cannot execute (codex under /root, linked from /usr/local/bin) fails, naming the agent and Permission denied" do
    write_file "farmy.yml", "agents:\n  codex:\n    install: mkdir -p /root/.codex/bin && printf '#!/bin/sh\\necho codex-cli 0.0.0\\n' > /root/.codex/bin/codex && chmod 755 /root/.codex/bin/codex && ln -sf /root/.codex/bin/codex /usr/local/bin/codex\n"

    script "farmy", "start", "shop"

    assert_failure
    assert_output_names "codex", "Permission denied"
  end

  test "a toolbox build whose agent's version command never answers fails after 30 s, naming the agent and the limit" do
    write_file "farmy.yml", "agents:\n  mytool:\n    install: printf '#!/bin/sh\\nsleep 600\\n' > /usr/local/bin/mytool && chmod 755 /usr/local/bin/mytool\n    login: .mytool\n    version: mytool --version\n"

    script "farmy", "start", "shop"

    assert_failure
    assert_output_names "mytool", "30 s"
  end

  test "an agent whose install download fails fails the build at the install step, naming the agent and the download's error" do
    write_file "farmy.yml", "agents:\n  mytool:\n    install: curl -fsSL -o /tmp/mytool-install.sh https://example.com/mytool/install.sh && sh /tmp/mytool-install.sh\n    login: .mytool\n    version: mytool --version\n"

    script "farmy", "start", "shop"

    assert_failure
    assert_output_names "mytool", "curl: (22)"
    refute_output_names "mytool: not found", because: "the build stops at the failed install, before the as-dev version check"
  end
end
