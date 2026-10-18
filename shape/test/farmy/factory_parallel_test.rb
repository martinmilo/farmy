class FactoryParallelTest < AcceptanceTest
  test "two simultaneous service runs use isolated sidecar projects data volumes and no published ports" do
    database_factory

    first, second = two_live_database_runs

    assert_distinct_gate_databases first, second
    assert_database_isolation
  end

  test "cancelling one database gate removes only its resources while the other retains its data and completes" do
    database_factory
    first, second = two_live_database_runs

    farmy "factory", "cancel", first

    assert_success
    assert_gate_resources_removed first
    assert_database_gate_alive second, marker: "cobalt"
    release_database_gate "cobalt"
    wait_run second, result: "green"
    assert_developer_database_untouched
  end

  test "a successful database gate cleans up its own sidecars and volumes while preserving developer data" do
    database_factory
    agent_plays({ writes: { "src/app.txt" => "amber\n" } })
    factory_start profile: "work", wait: false
    child = run_id
    wait_database_gate "amber"

    release_database_gate "amber"

    wait_run child, result: "green"
    assert_gate_resources_removed child
    assert_developer_database_untouched
  end

  test "gate_setup runs against healthy fresh sidecars before check and test" do
    database_factory
    agent_plays({ writes: { "src/app.txt" => "amber\n" } })

    factory_start profile: "work", wait: false
    child = run_id
    wait_database_gate "amber"

    assert_schema_before_test
    release_database_gate "amber"
    wait_run child, result: "green"
  end

  test "a later gate iteration receives a fresh database rather than the earlier iteration's data" do
    database_factory
    require_cobalt_after_database_check
    agent_plays({ writes: { "src/app.txt" => "amber\n" } }, { writes: { "src/app.txt" => "cobalt\n" } })
    factory_start profile: "work", wait: false
    child = run_id
    wait_database_gate "amber"

    release_database_gate "amber"

    wait_database_gate "cobalt"
    release_database_gate "cobalt"
    wait_run child, result: "green"
    assert_developer_database_untouched
  end

  test "sidecar health timeout is test_failed_to_run and no test SQL executes" do
    database_factory
    gate_sidecars_unhealthy
    agent_plays({ writes: { "src/app.txt" => "amber\n" } })

    factory_start profile: "work"

    assert_exit 1
    assert_stdout "test_failed_to_run"
    assert_empty database_queries
    refute_pushed
  end

  { "privileged" => /privileged/i, "Docker socket" => /docker.sock|Docker.socket/i,
    "host networking" => /host.network|network.*host/i, "external network" => /external.*network|network.*external/i }.each do |kind, reason|
    test "#{kind} in a gate sidecar is refused before the agent runs" do
      database_factory
      unsafe_gate_sidecar kind

      factory_start profile: "work"

      assert_exit 1
      assert_stderr reason
      assert_agent_count 0
      assert_no_gate_projects
    end
  end

  test "the default concurrency cap admits two simultaneous starts and queues the third without overshooting" do
    profiled_factory
    agent_plays({ barrier: "first-slot", writes: { "src/app.txt" => "fixed\n" } },
                { barrier: "second-slot", writes: { "src/app.txt" => "fixed\n" } },
                { barrier: "third-slot", writes: { "src/app.txt" => "fixed\n" } })

    simultaneously ["factory", "start", "shop", "--profile", "work", "--task", "First change"],
                   ["factory", "start", "shop", "--profile", "work", "--task", "Second change"],
                   ["factory", "start", "shop", "--profile", "work", "--task", "Third change"]

    assert_simultaneous_success
    wait_agent_barrier "first-slot"
    wait_agent_barrier "second-slot"
    assert_agent_count 2
    assert_queued_count 1
    release_agent_barrier "first-slot"
    wait_agent_barrier "third-slot"
    assert_agent_count 3
  end

  test "a concurrency limit of one queues a pipeline child behind a direct run and releases the slot after completion" do
    pipeline_factory steps: ["work"], concurrency: 1
    occupy_factory_slot
    agent_plays({ barrier: "pipeline-slot", writes: { "src/app.txt" => "fixed\n" } })

    id = pipeline_start wait: false

    assert_success
    assert_agent_count 1
    assert_factory_queued current_pipeline_run(id)
    release_agent_barrier "occupied-slot"
    wait_agent_barrier "pipeline-slot"
    assert_agent_count 2
  end

  test "two queued runs start FIFO as the service's occupied execution slot is released" do
    pipeline_factory concurrency: 1
    occupy_factory_slot
    agent_plays({ barrier: "first-queued", writes: { "src/app.txt" => "fixed\n" } },
                { barrier: "second-queued", writes: { "src/app.txt" => "fixed\n" } })
    first = queue_factory_task "First queued greeting."
    second = queue_factory_task "Second queued greeting."

    release_agent_barrier "occupied-slot"

    wait_agent_barrier "first-queued"
    assert_barrier_run "first-queued", first
    assert_last_agent_prompt "First queued greeting."
    assert_factory_queued second
    release_agent_barrier "first-queued"
    wait_agent_barrier "second-queued"
    assert_barrier_run "second-queued", second
    assert_last_agent_prompt "Second queued greeting."
    release_agent_barrier "second-queued"
    wait_run second, result: "green"
  end

  test "a reviewing pipeline releases its execution slot for another run" do
    pipeline_factory concurrency: 1
    pipeline_review
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start profile: "work"

    assert_success
    assert_stdout "green"
    assert_agent_count 2
  end

  test "a questioned worker releases its one execution slot for the answering shaper" do
    pipeline_factory steps: ["work"], concurrency: 1
    agent_plays({ writes: { ".farmy/question.md" => "Which greeting?\n" } }, { barrier: "answer-slot" })

    id = pipeline_start wait: false

    assert_success
    wait_agent_barrier "answer-slot"
    assert_agent_count 2
    pipeline_status id
    assert_pipeline_status id, profile: "shape", handoffs: 1
  end

  test "a full service concurrency cap does not consume another service's slots" do
    pipeline_factory concurrency: 1
    occupy_factory_slot
    another_factory_service

    farmy "factory", "start", "catalogue", "--profile", "work", "--task", "Fix the catalogue greeting.", "--wait"

    assert_success
    assert_stdout "green"
    assert_agent_count 2
  end

  test "gate network none creates no sidecar copies" do
    factory_service sidecar: true, gate: { "network" => "none" }
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_success
    assert_no_gate_projects
    assert_equal ["none"], run_networks("test")
  end
end
