# Independent gates and human handoffs: the fake plays agents, while git and the gate run on real files.
class FactoryProfilesTest < AcceptanceTest
  test "a legacy factory block runs as the default profile with its existing green gate" do
    factory_service
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })
    factory_start profile: "default"
    assert_success
    id = run_id

    farmy "status", "--json"

    assert_run_status id, profile: "default", result: "green"
  end

  test "a selected profile uses its own agent subscription mode timeout and iteration limit even when an api route exists" do
    profiled_factory work: { agent: "scribe", mode: "subscription", max_iterations: 1, iteration_timeout: "7s" },
                     model: :both, extra_config: fixture("farmy/factory-scribe.yml")
    agent_plays({ writes: { "src/app.txt" => "nearly\n" } })

    factory_start profile: "work"

    assert_exit 1
    assert_stdout "max_iterations"
    assert_agent_count 1
    assert_last_agent_command "scribe --batch"
    assert_last_agent_command "timeout 7"
    assert_run_env "agent", "CLAUDE_CODE_OAUTH_TOKEN"
    refute_run_env "agent", "ANTHROPIC_BASE_URL"
  end

  test "a shape run with a checked failing test pushes a draft while waiting for review and hides its configured source path" do
    profiled_factory
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } })

    factory_start profile: "shape"

    assert_exit 2
    assert_stdout "awaiting_review"
    assert_draft_pushed run_id
    assert_covered "agent", "/workspace/src"
    assert_agent_count 1
  end

  test "approving a published draft marks its exact gated commit green" do
    profiled_factory
    id = shape_run_awaiting_review

    farmy "factory", "approve", id

    assert_success
    assert_stdout "green"
    assert_pushed "farmy/shop/#{id}", commits: ["farmy: iteration 1"]
    assert_agent_count 1
  end

  { "run ID" => :id, "branch" => :branch }.each do |label, source_kind|
    test "a work run from an approved shape #{label} retains its test receives its failure output and goes green" do
      profiled_factory
      source = approved_shape_run
      agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

      factory_start profile: "work", from: factory_source(source, as: source_kind)

      assert_success
      assert_stdout "green"
      assert_run_file run_id, "test/check.sh", expected("factory/shaped-check.sh")
      assert_last_agent_prompt "Expected src/app.txt to say fixed", "exit 1"
      assert_pushed "farmy/shop/#{run_id}", commits: ["farmy: iteration 1", "farmy: iteration 1"]
      assert_checkout_unchanged
    end
  end

  { "run ID" => :id, "branch" => :branch }.each do |label, source_kind|
    test "starting from an unapproved shape #{label} refuses approval bypass before another agent runs" do
      profiled_factory
      source = shape_run_awaiting_review

      factory_start profile: "work", from: factory_source(source, as: source_kind)

      assert_exit 1
      assert_stderr(/approv|review/i)
      assert_stderr source
      assert_agent_count 1
      assert_draft_pushed source
    end
  end

  test "a red_first gate does not pass when its check command fails even though its test fails too" do
    profiled_factory shape: { max_iterations: 1 }, commands: { "check" => "echo 'suite does not load'; exit 2" }
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } })

    factory_start profile: "shape"

    assert_exit 1
    assert_stdout "max_iterations"
    refute_pushed
  end

  test "a red_first gate does not pass when its changed test exits zero" do
    profiled_factory shape: { max_iterations: 1 }
    agent_plays({ writes: { "test/check.sh" => "exit 0\n" } })

    factory_start profile: "shape"

    assert_exit 1
    assert_stdout "max_iterations"
    refute_pushed
  end

  test "a red_first gate does not pass without an added or changed committed file under writes" do
    profiled_factory shape: { max_iterations: 1 }
    agent_plays({ says: "The existing tests already fail." })

    factory_start profile: "shape"

    assert_exit 1
    assert_stdout "max_iterations"
    refute_pushed
  end

  test "a custom gate passes when its named command exits zero even though the ordinary test stays red" do
    profiled_factory work: { gate: "release" }, commands: { "release" => "test -f src/approved.txt" }
    agent_plays({ writes: { "src/approved.txt" => "ready\n" } })

    factory_start profile: "work"

    assert_success
    assert_stdout "green"
  end

  test "a red_first gate does not pass when the only committed change deletes a file under writes" do
    profiled_factory shape: { max_iterations: 1 }, files: { "test/notes.txt" => "Keep the suite readable.\n" }
    agent_plays({ deletes: ["test/notes.txt"] })

    factory_start profile: "shape"

    assert_exit 1
    assert_stdout "max_iterations"
    refute_pushed
  end

  test "a custom gate stays red when its named command fails even though the ordinary test passes" do
    profiled_factory work: { gate: "release", max_iterations: 1 }, commands: { "release" => "test -f src/approved.txt" }
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start profile: "work"

    assert_exit 1
    assert_stdout "max_iterations"
    refute_pushed
  end

  test "a green gate waits for review when the profile explicitly requires it" do
    profiled_factory work: { review: true }
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start profile: "work"

    assert_exit 2
    assert_stdout "awaiting_review"
    assert_draft_pushed run_id
  end

  test "a red_first gate completes green when the profile explicitly disables review" do
    profiled_factory shape: { review: false }
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } })

    factory_start profile: "shape"

    assert_success
    assert_stdout "green"
    assert_pushed "farmy/shop/#{run_id}", commits: ["farmy: iteration 1"]
  end

  test "an agent can ask outside writes and show prints the question without committing it or running a gate" do
    profiled_factory
    agent_plays({ writes: { ".farmy/question.md" => "What should src/app.txt say?\n" } })
    factory_start profile: "work"
    assert_exit 2
    assert_stdout "question"
    id = run_id

    farmy "factory", "show", id

    assert_stdout "What should src/app.txt say?"
    refute_path_in_run_history id, ".farmy/question.md"
    assert_gate_count 0
    refute_pushed
  end

  test "answering a question continues its committed work on a new run and supplies the task question and answer" do
    profiled_factory
    source = questioned_work_run writes: { "src/notes.txt" => "Keep the greeting simple.\n" }
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_answer source, "Use fixed."

    assert_success
    assert_stdout "green"
    assert_continues_run run_id, source
    assert_run_file run_id, "src/notes.txt", "Keep the greeting simple.\n"
    assert_last_agent_prompt "Fix the output in src/app.txt.", "What should src/app.txt say?", "Use fixed."
    refute_path_in_run_history run_id, ".farmy/question.md"
  end

  test "a question is never committed even when the legacy profile may write the whole repository" do
    factory_service
    agent_plays({ writes: { ".farmy/question.md" => "What should src/app.txt say?\n" } })

    factory_start

    assert_exit 2
    assert_stdout "question"
    refute_path_in_run_history run_id, ".farmy/question.md"
    assert_gate_count 0
  end

  test "answer reads an existing file in the containers folder into the next prompt" do
    profiled_factory
    source = questioned_work_run
    write_file "answer.txt", "Use fixed from the agreed answer.\n"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_answer source, "answer.txt"

    assert_success
    assert_last_agent_prompt "Use fixed from the agreed answer."
  end

  test "even a custom prompt explains the question file that may be written outside writes" do
    profiled_factory
    write_file "factory/prompt.md", "TASK={{TASK}}\n{{TEST_OUTPUT}}\n"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start profile: "work"

    assert_success
    assert_last_agent_prompt ".farmy/question.md"
  end

  test "two empty iterations with identical failing gate output stall without spending a third iteration" do
    factory_service max_iterations: 5
    agent_plays({}, {}, { writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_exit 1
    assert_stdout "stalled"
    assert_agent_count 2
    assert_gate_count 2
    refute_pushed
  end

  test "a commit between empty iterations breaks the stalled sequence" do
    factory_service max_iterations: 6
    agent_plays({}, { writes: { "src/app.txt" => "nearly\n" } }, {}, {})

    factory_start

    assert_exit 1
    assert_stdout "stalled"
    assert_agent_count 4
    refute_pushed
  end

  test "changed gate output between empty iterations breaks the stalled sequence" do
    factory_service max_iterations: 3, check: "printf 'Gate process %s still fails\\n' \"$$\"; exit 1\n"
    agent_plays({}, {}, {})

    factory_start

    assert_exit 1
    assert_stdout "max_iterations"
    assert_agent_count 3
  end

  test "a shape agent source edit outside writes is dropped before the gate and reaches no commit" do
    profiled_factory shape: { hidden: [] }
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh"), "src/app.txt" => "fixed\n" } })

    factory_start profile: "shape"

    assert_exit 2
    assert_stdout "awaiting_review"
    assert_run_file run_id, "src/app.txt", "broken\n"
    assert_draft_pushed run_id
  end

  test "a worker test edit is dropped while the approved shaper test remains the gate" do
    profiled_factory
    source = approved_shape_run
    agent_plays({ writes: { "src/app.txt" => "fixed\n", "test/check.sh" => "exit 0\n" } })

    factory_start profile: "work", from: source

    assert_success
    assert_run_file run_id, "test/check.sh", expected("factory/shaped-check.sh")
  end

  test "a two profile build uses configured names and paths rather than shape work test or src conventions" do
    profiled_factory shape: { writes: ["specs/"], hidden: ["lib/"] }, work: { writes: ["lib/"], protects: ["specs/"] },
                     files: { "lib/greeting.txt" => "pending\n", "specs/check.sh" => "test -f lib/greeting.txt\n" },
                     commands: { "test" => "sh specs/check.sh", "check" => "sh -n specs/check.sh" }
    rename_factory_profiles shape: "describe", work: "build"
    source = approved_custom_shape_run
    agent_plays({ writes: { "lib/greeting.txt" => "ready\n" } })

    factory_start profile: "build", from: source

    assert_success
    assert_run_file run_id, "specs/check.sh", "grep -q ready lib/greeting.txt\n"
    assert_run_file run_id, "lib/greeting.txt", "ready\n"
  end

  test "status supplies the TUI with the profile and awaiting_review result" do
    profiled_factory
    id = shape_run_awaiting_review

    farmy "status", "--json"

    assert_run_status id, profile: "shape", result: "awaiting_review", phase: "done"
  end

  test "status supplies the TUI with the question text and its profile" do
    profiled_factory
    id = questioned_work_run

    farmy "status", "--json"

    assert_run_status id, profile: "work", result: "question", question: "What should src/app.txt say?\n"
  end

  test "an unknown profile is refused by name with available profiles before an agent starts" do
    profiled_factory

    factory_start profile: "release"

    assert_exit 1
    assert_stderr "release"
    assert_stderr "shape"
    assert_stderr "work"
    assert_agent_count 0
    refute_pushed
  end

  test "omitting the profile is refused when several profiles exist and none is default" do
    profiled_factory

    factory_start

    assert_exit 1
    assert_stderr "--profile"
    assert_stderr "shape"
    assert_stderr "work"
    assert_agent_count 0
  end

  test "a red_first profile with a missing named check command is refused before an agent starts" do
    profiled_factory shape: { check: "load-suite" }

    factory_start profile: "shape"

    assert_exit 1
    assert_stderr "load-suite"
    assert_stderr "commands"
    assert_agent_count 0
  end

  test "a run that has not passed its gate cannot be approved" do
    profiled_factory work: { max_iterations: 1 }
    agent_plays({ writes: { "src/app.txt" => "nearly\n" } })
    factory_start profile: "work"
    assert_stdout "max_iterations"
    id = run_id

    farmy "factory", "approve", id

    assert_exit 1
    assert_stderr "awaiting_review"
    refute_pushed
  end

  test "prune keeps the volume of a published draft awaiting review so it can be revised or approved" do
    profiled_factory
    id = shape_run_awaiting_review

    farmy "factory", "prune"

    assert_success
    assert_volume "shop-run-#{id}"
    farmy "factory", "approve", id
    assert_success
  end

  test "prune keeps the volume of a questioned run so an answer can continue it" do
    profiled_factory
    id = questioned_work_run

    farmy "factory", "prune"

    assert_success
    assert_volume "shop-run-#{id}"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })
    factory_answer id, "Use fixed."
    assert_success
  end
end
