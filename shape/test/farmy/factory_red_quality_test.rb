class FactoryRedQualityTest < AcceptanceTest
  test "red_first accepts checked changed tests whose nonzero output matches red_pattern" do
    profiled_factory shape: { gate: { "kind" => "red_first", "red_pattern" => "Expected src/app.txt to say fixed", "red_exit_codes" => [1] } }
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } })

    factory_start profile: "shape"

    assert_exit 2
    assert_stdout "awaiting_review"
    assert_draft_pushed run_id
  end

  test "red_pattern also matches the test's stderr rather than only stdout" do
    profiled_factory shape: { gate: { "kind" => "red_first", "red_pattern" => "Greeting assertion failed" } }
    agent_plays({ writes: { "test/check.sh" => "printf '%s\\n' 'Greeting assertion failed' >&2\nexit 1\n" } })

    factory_start profile: "shape"

    assert_exit 2
    assert_stdout "awaiting_review"
    assert_draft_pushed run_id
  end

  test "a nonzero test without its red_pattern match cannot become a reviewed red" do
    profiled_factory shape: { max_iterations: 1, gate: { "kind" => "red_first", "red_pattern" => "Greeting assertion failed" } }
    agent_plays({ writes: { "test/check.sh" => "echo 'suite cannot load'\nexit 1\n" } })

    factory_start profile: "shape"

    assert_exit 1
    assert_stdout "max_iterations"
    refute_pushed
  end

  test "a matching pattern cannot replace a successful check command" do
    profiled_factory shape: { max_iterations: 1, gate: { "kind" => "red_first", "red_pattern" => "Expected src/app.txt" } }, commands: { "check" => "exit 2" }
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } })

    factory_start profile: "shape"

    assert_exit 1
    assert_stdout "max_iterations"
    refute_pushed
  end

  test "a matching pattern cannot make a zero test exit red" do
    profiled_factory shape: { max_iterations: 1, gate: { "kind" => "red_first", "red_pattern" => "Greeting assertion failed" } }
    agent_plays({ writes: { "test/check.sh" => "echo 'Greeting assertion failed'\nexit 0\n" } })

    factory_start profile: "shape"

    assert_exit 1
    assert_stdout "max_iterations"
    refute_pushed
  end

  test "matching failing output without any changed committed file under writes cannot satisfy red_first" do
    profiled_factory shape: { max_iterations: 1, gate: { "kind" => "red_first", "red_pattern" => "Greeting assertion failed" } }, check: "echo 'Greeting assertion failed'; exit 1\n"
    agent_plays({ says: "The existing failure is enough." })

    factory_start profile: "shape"

    assert_exit 1
    assert_stdout "max_iterations"
    refute_pushed
  end

  test "red_first refuses a deletion-only commit even when check passes and test output matches an allowed failure exit" do
    profiled_factory shape: { max_iterations: 1, gate: { "kind" => "red_first", "red_pattern" => "Greeting assertion failed", "red_exit_codes" => [1] } },
                     files: { "test/notes.txt" => "Describe the greeting expectation.\n" }, commands: { "check" => "exit 0", "test" => "echo 'Greeting assertion failed'; exit 1" }
    agent_plays({ deletes: ["test/notes.txt"] })

    factory_start profile: "shape"

    assert_exit 1
    assert_stdout "max_iterations"
    refute_pushed
  end

  test "red_exit_codes narrows matching failures so exit 2 is not accepted when only exit 1 is allowed" do
    profiled_factory shape: { max_iterations: 1, gate: { "kind" => "red_first", "red_pattern" => "Greeting assertion failed", "red_exit_codes" => [1] } }
    agent_plays({ writes: { "test/check.sh" => "echo 'Greeting assertion failed'\nexit 2\n" } })

    factory_start profile: "shape"

    assert_exit 1
    assert_stdout "max_iterations"
    refute_pushed
  end

  test "red_exit_codes can explicitly accept the suite's ordinary exit 2 assertion convention" do
    profiled_factory shape: { gate: { "kind" => "red_first", "red_pattern" => "Greeting assertion failed", "red_exit_codes" => [2] } }
    agent_plays({ writes: { "test/check.sh" => "echo 'Greeting assertion failed'\nexit 2\n" } })

    factory_start profile: "shape"

    assert_exit 2
    assert_stdout "awaiting_review"
    assert_draft_pushed run_id
  end

  test "a test container that fails to launch is test_failed_to_run even with a permissive red_pattern" do
    profiled_factory shape: { gate: { "kind" => "red_first", "red_pattern" => ".*" } }
    fail_role "test"
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } })

    factory_start profile: "shape"

    assert_exit 1
    assert_stdout "test_failed_to_run"
    refute_pushed
  end

  { "invalid" => "[unclosed", "empty" => "" }.each do |label, pattern|
    test "an #{label} red_pattern is refused before any agent runs" do
      profiled_factory shape: { gate: { "kind" => "red_first", "red_pattern" => pattern } }

      factory_start profile: "shape"

      assert_exit 1
      assert_stderr "red_pattern"
      assert_agent_count 0
      refute_factory_run_volumes
    end
  end

  test "red_first without red_pattern keeps its gate behavior but status and show call it red unverified" do
    profiled_factory
    child = shape_run_awaiting_review

    farmy "status", "--json"

    assert_run_status child, result: "awaiting_review", gate_summary: "red (unverified)"
    farmy "factory", "show", child
    assert_stdout "red (unverified)"
    refute_stdout "meaningful red"
  end

  test "an unknown gate_setup command is refused before any agent runs" do
    profiled_factory work: { gate_setup: "load-schema" }

    factory_start profile: "work"

    assert_exit 1
    assert_stderr "load-schema"
    assert_stderr "commands"
    assert_agent_count 0
    refute_factory_run_volumes
  end

  test "a failed gate_setup is test_failed_to_run and cannot count as red even if its output matches" do
    profiled_factory shape: { gate_setup: "schema", gate: { "kind" => "red_first", "red_pattern" => "Greeting assertion failed" } },
                     commands: { "schema" => "echo 'Greeting assertion failed during schema load'; exit 1" }
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } })

    factory_start profile: "shape"

    assert_exit 1
    assert_stdout "test_failed_to_run"
    refute_pushed
  end

  test "gate_setup runs in the exported gate checkout before the red_first check command" do
    profiled_factory shape: { gate_setup: "schema", gate: { "kind" => "red_first", "red_pattern" => "Greeting assertion failed" } },
                     commands: { "schema" => "touch .schema-ready", "check" => "test -f .schema-ready && sh -n test/check.sh" }
    agent_plays({ writes: { "test/check.sh" => "test -f .schema-ready || exit 2\necho 'Greeting assertion failed'\nexit 1\n" } })

    factory_start profile: "shape"

    assert_exit 2
    assert_stdout "awaiting_review"
    assert_draft_pushed run_id
  end
end
