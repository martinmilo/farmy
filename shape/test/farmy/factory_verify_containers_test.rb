# Where a verify runs: a fresh container per call, isolated as the gate's test container, with fresh sidecars of its
# own, one at a time per run, never longer than the agent's iteration; the agent stays where it was. verify_service
# makes shop with verify: test and one iteration; test/check.sh prints `args:` and each argument in brackets, then
# `src/app.txt says fixed` (exit 0) or `src/app.txt does not say fixed yet` (exit 3).
class FactoryVerifyContainersTest < AcceptanceTest
  test "each verify runs in a fresh container labelled farmy.role=verify, the run volume read-only, with a scratch tmpfs and no way out" do
    verify_service
    agent_plays({ steps: [{ run: "farmy-verify" }, { run: "farmy-verify" }] })

    factory_start

    assert_equal ["shop-run-#{run_id}-verify-1-1", "shop-run-#{run_id}-verify-1-2"], verify_containers.map { |r| r["name"] },
                 "Expected one fresh container per farmy-verify call, named <name>-run-<id>-verify-<iteration>-<k> and labelled farmy.role=verify."
    assert_run_mount "verify", "shop-run-#{run_id}", at: "/workspace", readonly: true
    assert_run_tmpfs "verify", "/scratch"
    assert_verify_has_no_way_out
  end

  test "a verify gets fresh sidecars of its own in shop-run-<id>-verify, removed when it ends, and the developer's sidecar never joins" do
    verify_service sidecar: :health_checked
    agent_plays({ steps: [{ run: "farmy-verify" }] })

    factory_start

    assert_agent_got 1, exit: 3
    assert_verify_sidecar "postgres", original: "shop-pg"
  end

  test "with the gate's network none a verify runs with no network and starts no sidecars" do
    verify_service sidecar: :health_checked, gate: { "network" => "none" }
    agent_plays({ writes: { "src/app.txt" => "fixed\n" }, steps: [{ run: "farmy-verify" }] })

    factory_start

    assert_agent_got 1, exit: 0
    assert_equal [["none"]], verify_containers.map { |r| Array(r["networks"]) }, "Expected the verify container with --network none, as its gate."
    refute_verify_sidecars
  end

  test "a second verify called while one runs waits for it, and each call gets its own result" do
    verify_service commands: { "slow" => "sleep 2 && sh test/check.sh" }, verify: "slow"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" },
                  steps: [{ run: "farmy-verify first", background: true }, { sleep: 0.5 }, { run: "farmy-verify second" }] })

    factory_start

    assert_one_verify_at_a_time
    assert_agent_got 1, exit: 0, stdout: "args: [first]"
    assert_agent_got 3, exit: 0, stdout: "args: [second]"
  end

  test "a verify still running when the agent is stopped at iteration_timeout is stopped with it" do
    verify_service commands: { "slow" => "sleep 30" }, verify: "slow", iteration_timeout: "2s"
    agent_plays({ steps: [{ run: "farmy-verify" }] })

    factory_start

    assert_stdout "timeout"
    refute_running "shop-run-#{run_id}-verify-1-1"
    assert_includes verify_record(1, 1)["reason"].to_s, "stopped", "Expected the verify's record to say it was stopped when the agent's container ended."
  end

  test "in token mode, with no broker, farmy-verify works while the agent stays on internal networks, with no Docker socket and no farmy binary" do
    verify_service model: :token
    agent_plays({ writes: { "src/app.txt" => "fixed\n" }, steps: [{ run: "farmy-verify" }] })

    factory_start

    assert_agent_got 1, exit: 0, stdout: "src/app.txt says fixed"
    assert_agents_filtered
    refute_agent_reaches_docker_or_farmy
  end
end
