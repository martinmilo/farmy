# A login turn ends only when the agent container holding it is gone. A controller killed mid-turn leaves its
# agent container running (Docker keeps a container when its client dies); the next run on that factory login
# stops such an orphan before its own agent starts, and records that it did. login_factory sets up shop with
# profile work running codex in mode: login; the agent does what agent_plays says.
class FactoryLoginOrphansTest < AcceptanceTest
  test "a login-mode agent container is labelled with its factory login" do
    login_factory
    logged_in "codex"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start profile: "work"

    assert_success
    labels = run_containers("agent").map { |r| r["labels"]["farmy.factory-login"] }
    assert_equal ["codex"], labels, "Expected the agent container of a login-mode run labelled farmy.factory-login=codex.#{transcript}"
  end

  test "a controller killed mid-turn leaves its agent running, and the next run on that login stops the orphan and its run's egress gate before its own agent starts and records both" do
    first, orphan = orphaned_codex_agent
    gate = "shop-run-#{first}-egress-gate"
    assert_still_running gate

    factory_start profile: "work"

    assert_success
    second = run_id
    refute_running orphan
    refute_running gate
    assert_stopped_before_started orphan, "shop-run-#{second}-agent-1"
    assert_equal [{ "container" => orphan, "run" => first, "gate" => gate }], orphans_stopped, "Expected orphans_stopped to record the orphan, its run and its run's egress gate, removed with it.#{transcript}"
    farmy "factory", "show", second
    assert_stdout "stopped orphaned agent container #{orphan}"
    assert_stdout gate
  end

  test "an orphaned agent container of another factory login is left running" do
    profiled_factory shape: { agent: "mytool", mode: "login" }, work: { agent: "codex", mode: "login" },
                     extra_config: mytool_agent(factory_login: "{path: .mytool, create: mytool auth --device}")
    logged_in "mytool"
    logged_in "codex"
    agent_plays({ barrier: "mytool-turn" }, { writes: { "src/app.txt" => "fixed\n" } })
    factory_start profile: "shape", wait: false
    first = run_id
    wait_agent_barrier "mytool-turn"
    kill_controller first

    factory_start profile: "work"

    assert_success
    assert_still_running "shop-run-#{first}-agent-1"
    assert_empty orphans_stopped
  end

  test "an agent container of the same factory login from another containers folder is left running" do
    login_factory
    logged_in "codex"
    other = another_folders_login_agent "codex"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start profile: "work"

    assert_success
    assert_still_running other
    assert_empty orphans_stopped
  end

  test "an orphan that cannot be removed is tried again over about 10 s, then the run refuses to start its agent, naming the container and Docker's error" do
    _first, orphan = orphaned_codex_agent
    removal_fails orphan, times: :always

    factory_start profile: "work"

    second = run_id
    assert_removal_tried orphan, at_least: 3
    assert_agent_count 1
    assert_equal "login_blocked", run_state["result"], "Expected the run that could not remove the orphan to end login_blocked, its agent never started.#{transcript}"
    farmy "factory", "show", second
    assert_stdout orphan
    assert_stdout "permission denied"
  end

  test "an orphan whose removal fails at first and then works is removed, and the run goes on" do
    first, orphan = orphaned_codex_agent
    removal_fails orphan, times: 2

    factory_start profile: "work"

    assert_success
    refute_running orphan
    assert_equal [orphan], orphans_stopped.map { |o| o["container"] }
    assert_equal [first], orphans_stopped.map { |o| o["run"] }
  end
end
