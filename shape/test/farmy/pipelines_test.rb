# The complete pipeline is driven through the public CLI. Agents only edit fixture files;
# farmy owns every transition, publication, approval and continuation.
class PipelinesTest < AcceptanceTest
  ["Make the greeting fixed.", "task.txt"].each do |task|
    test "pipeline start reads #{task} and runs its configured profiles in order" do
      pipeline_factory shape: { review: false }
      write_file "task.txt", "Make the greeting fixed.\n"
      agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } }, { writes: { "src/app.txt" => "fixed\n" } })

      id = pipeline_start task: task

      assert_success
      assert_pipeline_profiles id, %w[shape work]
      assert_all_agent_prompts "Make the greeting fixed."
    end
  end

  test "an unknown pipeline is refused by name before any agent or run volume is created" do
    pipeline_factory

    pipeline_start name: "release"

    assert_exit 1
    assert_stderr "release"
    assert_agent_count 0
    refute_factory_run_volumes
  end

  test "an unknown step profile is refused before the earlier valid step can start" do
    pipeline_factory steps: %w[shape missing-profile]

    pipeline_start

    assert_exit 1
    assert_stderr "missing-profile"
    assert_agent_count 0
    refute_factory_run_volumes
  end

  test "status provides pipeline identity current step and waiting child to the TUI" do
    pipeline_factory
    id, child = pipeline_review

    pipeline_status id

    assert_pipeline_status id, name: "build", state: "awaiting_review", step: 1, steps: 2, profile: "shape", active_run: child, handoffs: 0
    assert_run_status child, pipeline_id: id, pipeline_name: "build", pipeline_step: 1
  end

  test "pipeline list and show identify its current shape step and the draft awaiting review" do
    pipeline_factory
    id, child = pipeline_review

    farmy "factory", "pipeline", "list"
    assert_stdout id
    assert_stdout "shape"
    farmy "factory", "pipeline", "show", id
    assert_stdout "awaiting_review"
    assert_stdout child
  end

  test "ordinary factory list and show expose the child's pipeline and current step" do
    pipeline_factory
    id, child = pipeline_review

    farmy "factory", "list"
    assert_stdout id
    assert_stdout "shape"
    farmy "factory", "show", child
    assert_stdout id
    assert_stdout "shape"
  end

  test "cancelling a pipeline stops its active child and records cancelled in public status" do
    pipeline_factory steps: ["work"]
    agent_plays({ barrier: "cancel-child" })
    id = pipeline_start wait: false
    assert_success
    wait_agent_barrier "cancel-child"

    farmy "factory", "pipeline", "cancel", id

    assert_success
    assert_pipeline_stopped id, result: "cancelled"
  end

  test "prune retains reviewing pipeline history and the commit needed for revision or approval" do
    pipeline_factory
    id, child = pipeline_review

    farmy "factory", "prune"

    assert_success
    assert_volume "shop-run-#{child}"
    pipeline_status id
    assert_pipeline_status id, state: "awaiting_review", active_run: child
  end

  test "a checked shape draft is pushed before approval and no worker starts during review" do
    pipeline_factory
    id, child = pipeline_review

    assert_draft_pushed child
    assert_agent_count 1
    pipeline_status id
    assert_pipeline_status id, state: "awaiting_review", step: 1
  end

  {
    "GitHub HTTPS" => ["https://github.com/acme/shop.git", nil, nil, "https://github.com/acme/shop/compare/"],
    "GitHub SSH" => ["git@github.com:acme/shop.git", nil, nil, "https://github.com/acme/shop/compare/"],
    "GitLab" => ["https://gitlab.com/acme/shop.git", nil, nil, "https://gitlab.com/acme/shop/-/compare/"],
    "self-hosted GitLab" => ["ssh://git@gitlab.example.com/acme/shop.git", "gitlab", nil, "https://gitlab.example.com/acme/shop/-/compare/"],
    "Forgejo on a reviewer's network" => ["ssh://git@forge.example.com/acme/shop.git", "forgejo", nil, "https://forge.example.com/acme/shop/compare/"],
    "Gitea with a separate web URL" => ["ssh://git@git.example.com/acme/shop.git", "gitea", "https://review.example.com/acme/shop", "https://review.example.com/acme/shop/compare/"]
  }.each do |label, (repo, forge, web_url, prefix)|
    test "#{label} publishes an immutable compare URL in status and show even on a private review network" do
      profiled_factory
      review_repository repo, forge: forge, web_url: web_url
      child = shape_run_awaiting_review

      assert_compare_link child, prefix: prefix
      assert_draft_pushed child
    end
  end

  test "an unknown forge shows the branch as the review fallback" do
    profiled_factory
    review_repository "https://source.example.com/acme/shop.git"
    child = shape_run_awaiting_review

    farmy "factory", "show", child

    assert_stdout "farmy/shop/#{child}"
    refute_stdout "/compare/"
    assert_draft_pushed child
  end

  test "a local workbench with no remote can pause for local review with the branch fallback" do
    profiled_factory
    remove_review_remote
    child = shape_run_awaiting_review

    farmy "factory", "show", child

    assert_stdout "awaiting_review"
    assert_stdout "farmy/shop/#{child}"
    refute_stdout "/compare/"
  end

  test "failed draft publication ends publish_failed without exposing a usable compare URL or starting work" do
    pipeline_factory
    refuse_draft_push
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } })

    id = pipeline_start

    assert_exit 1
    assert_stdout "publish_failed"
    assert_agent_count 1
    refute_pushed
    assert_unpublished_review id
  end

  test "resuming publication retries the same gated commit without another agent or gate" do
    pipeline_factory
    refuse_draft_push
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } })
    id = pipeline_start
    accept_draft_push

    pipeline_resume id

    assert_exit 2
    assert_stdout "awaiting_review"
    assert_agent_count 1
    assert_gate_count 1
    assert_draft_pushed current_pipeline_run(id)
  end

  test "approval records its exact commit and an immutable profile and gate snapshot" do
    pipeline_factory
    id, child = pipeline_review
    remember_gated_commit child
    agent_plays({ barrier: "worker-started", writes: { "src/app.txt" => "fixed\n" } })

    farmy "factory", "approve", child

    assert_success
    change_shape_configuration
    assert_approved_commit child
    assert_profile_snapshot child, writes: ["test/"], check: "check"
    assert_gate_snapshot child, kind: "red_first"
    wait_agent_barrier "worker-started"
    assert_source_is_remembered_commit current_pipeline_run(id), child
  end

  test "revision after live profile edits uses the approved write permissions check and gate snapshot" do
    profiled_factory
    child = approved_shape_run
    change_shape_configuration check_command: "exit 7"
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check-revised.sh") } })

    factory_revise child, "Clarify the approved greeting failure."

    assert_exit 2
    assert_stdout "awaiting_review"
    revised = run_id
    assert_run_file revised, "test/check.sh", fixture("factory/shaped-check-revised.sh")
    assert_revision_of revised, child
    assert_profile_snapshot child, writes: ["test/"], check: "check"
    assert_gate_snapshot child, kind: "red_first"
  end

  { "run ID" => :id, "known branch" => :branch }.each do |label, source_kind|
    test "from an approved #{label} uses the approved commit after its branch advances" do
      profiled_factory
      child = approved_shape_run
      remember_gated_commit child
      move_run_branch child
      agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

      factory_start profile: "work", from: factory_source(child, as: source_kind)

      assert_success
      worker = run_id
      assert_source_is_remembered_commit worker, child
      assert_run_file worker, "test/check.sh", expected("factory/shaped-check.sh")
    end
  end

  test "moving a draft before approval is refused without starting downstream work" do
    pipeline_factory
    _, child = pipeline_review
    move_run_branch child

    farmy "factory", "approve", child

    assert_exit 1
    assert_stderr(/mov|chang|commit/i)
    assert_agent_count 1
  end

  test "two simultaneous approvals claim the same transition once and create one worker child" do
    pipeline_factory
    id, child = pipeline_review
    agent_plays({ barrier: "one-worker", writes: { "src/app.txt" => "fixed\n" } })

    simultaneously ["factory", "approve", child], ["factory", "approve", child]

    assert_simultaneous_success
    wait_agent_barrier "one-worker"
    assert_agent_count 2
    assert_child_identity_precedes_launch id
  end

  test "resume reconciles its preassigned live child and simultaneous resumes never launch it twice" do
    pipeline_factory steps: ["work"]
    agent_plays({ barrier: "orphaned-child", writes: { "src/app.txt" => "fixed\n" } })
    id = pipeline_start wait: false
    assert_success
    wait_agent_barrier "orphaned-child"
    child = current_pipeline_run(id)
    interrupt_pipeline_controller id

    simultaneously ["factory", "pipeline", "resume", id], ["factory", "pipeline", "resume", id]

    assert_simultaneous_success
    assert_agent_count 1
    assert_pipeline_keeps_child id, child
    release_agent_barrier "orphaned-child"
    wait_pipeline id, state: "green"
  end

  test "resume cleans an interrupted checkout before first launch and completes the durably preassigned child exactly once" do
    pipeline_factory steps: ["work"]
    hold_next_checkout_volume "incomplete-launch"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })
    id = pipeline_start wait: false
    assert_success
    child = assert_preassigned_child_at_volume_barrier id, barrier: "incomplete-launch"
    crash_incomplete_pipeline id, child: child

    pipeline_resume id

    assert_success
    assert_agent_count 1
    assert_pipeline_keeps_child id, child
    assert_run_file child, "src/app.txt", "fixed\n"
    refute_run_file child, "src/incomplete-launch.txt"
  end

  test "pipeline start --wait leaves each child's checkout to that child, through a question, its answer and the continuation" do
    pipeline_factory steps: ["work"]
    hold_first_clone
    agent_plays({ writes: { ".farmy/question.md" => "Which greeting?\n" } }, { writes: { ".farmy/answer.md" => "Use fixed.\n" } },
                { writes: { "src/app.txt" => "fixed\n" } })

    pipeline_start

    assert_every_checkout_left_to_its_run
    assert_success
  end

  test "a detached pipeline controller leaves each child's checkout to that child, through a question, its answer and the continuation" do
    pipeline_factory steps: ["work"]
    hold_first_clone
    agent_plays({ writes: { ".farmy/question.md" => "Which greeting?\n" } }, { writes: { ".farmy/answer.md" => "Use fixed.\n" } },
                { writes: { "src/app.txt" => "fixed\n" } })
    id = pipeline_start wait: false

    wait_pipeline_settled id

    assert_every_checkout_left_to_its_run
    assert_pipeline_status id, state: "green"
  end

  test "resume cleans an interrupted checkout before relaunching, then leaves the relaunched child's checkout to the child" do
    pipeline_factory steps: ["work"]
    hold_next_checkout_volume "incomplete-launch"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })
    id = pipeline_start wait: false
    child = assert_preassigned_child_at_volume_barrier id, barrier: "incomplete-launch"
    crash_incomplete_pipeline id, child: child
    hold_first_clone

    pipeline_resume id

    assert_checkout_left_to_its_run child
    assert_success
  end

  test "revision creates a new shape attempt on the same branch with original task and literal feedback" do
    profiled_factory
    child = shape_run_awaiting_review
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check-revised.sh") } })

    factory_revise child, "Name the greeting failure clearly."

    assert_exit 2
    assert_stdout "awaiting_review"
    assert_last_agent_prompt "Describe the fixed output in a failing test.", "Name the greeting failure clearly."
    revised = run_id
    assert_revision_of revised, child
    assert_draft_pushed revised, branch: "farmy/shop/#{child}"
  end

  test "revision reads feedback from a file and retains the task" do
    profiled_factory
    child = shape_run_awaiting_review
    write_file "feedback.txt", "Explain the actual greeting mismatch.\n"
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check-revised.sh") } })

    factory_revise child, "feedback.txt"

    assert_exit 2
    assert_last_agent_prompt "Explain the actual greeting mismatch.", "Describe the fixed output in a failing test."
  end

  test "revising an approved attempt invalidates queued downstream work atomically and requires fresh approval" do
    pipeline_factory concurrency: 1
    id, child = pipeline_review
    occupy_factory_slot
    farmy "factory", "approve", child
    assert_success
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check-revised.sh") } })

    factory_revise child, "Review a stricter greeting assertion.", wait: false
    release_agent_barrier "occupied-slot"

    wait_pipeline id, state: "awaiting_review"
    assert_pipeline_status id, step: 1, profile: "shape"
    assert_no_pipeline_profile id, "work"
    assert_previous_approval_invalidated child
  end

  test "revision is refused after downstream execution starts and preserves the approval and active worker" do
    pipeline_factory
    id, child = pipeline_review
    remember_gated_commit child
    agent_plays({ barrier: "running-downstream", writes: { "src/app.txt" => "fixed\n" } })
    farmy "factory", "approve", child
    assert_success
    wait_agent_barrier "running-downstream"
    worker = current_pipeline_run(id)

    factory_revise child, "Change the greeting contract after work started."

    assert_exit 1
    assert_stderr(/downstream|started|running/i)
    assert_agent_count 2
    assert_pipeline_keeps_child id, worker
    assert_approved_commit child
    assert_run_status child, approval_valid: true
    release_agent_barrier "running-downstream"
    wait_pipeline id, state: "green"
  end

  test "a queued pipeline step retains the approval's commit after its branch moves" do
    pipeline_factory concurrency: 1
    id, child = pipeline_review
    remember_gated_commit child
    occupy_factory_slot
    farmy "factory", "approve", child
    move_run_branch child
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    release_agent_barrier "occupied-slot"

    wait_pipeline id, state: "green"
    assert_source_is_remembered_commit current_pipeline_run(id), child
    assert_run_file current_pipeline_run(id), "test/check.sh", expected("factory/shaped-check.sh")
  end

  test "a worker question invokes the configured answering profile using the question as its task" do
    pipeline_factory steps: ["work"]
    agent_plays({ writes: { ".farmy/question.md" => "Which greeting is required?\n" } }, { barrier: "answering" })
    id = pipeline_start wait: false
    assert_success

    wait_agent_barrier "answering"

    assert_last_agent_prompt "Which greeting is required?", ".farmy/answer.md"
    pipeline_status id
    assert_pipeline_status id, profile: "shape", handoffs: 1
  end

  test "a text-only answer continues without review and retains the worker's captured work" do
    pipeline_factory steps: ["work"]
    agent_plays({ writes: { "src/notes.txt" => "Preserve the greeting note.\n", ".farmy/question.md" => "Which greeting?\n" } },
                { writes: { ".farmy/answer.md" => "Use fixed.\n" } }, { writes: { "src/app.txt" => "fixed\n" } })

    id = pipeline_start

    assert_success
    assert_last_agent_prompt "Which greeting?", "Use fixed."
    assert_run_file current_pipeline_run(id), "src/notes.txt", "Preserve the greeting note.\n"
    assert_gate_count 1
  end

  test "review_answers true pauses even a text-only answer until a human approves it" do
    pipeline_factory steps: ["work"], review_answers: true
    agent_plays({ writes: { ".farmy/question.md" => "Which greeting?\n" } }, { writes: { ".farmy/answer.md" => "Use fixed.\n" } })
    id = pipeline_start
    assert_exit 2
    child = current_pipeline_run(id)
    assert_agent_count 2
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    farmy "factory", "approve", child

    assert_success
    wait_pipeline id, state: "green"
    assert_last_agent_prompt "Use fixed."
  end

  test "a permitted test answer must fail on the worker's question commit and wait for review before continuation" do
    pipeline_factory steps: ["work"]
    id, answer = pipeline_answer_review

    assert_draft_pushed answer
    assert_agent_count 2
    assert_answer_reference_is_question id, answer
    agent_plays({ writes: { "src/app.txt" => "resolved\n" } })
    farmy "factory", "approve", answer
    wait_pipeline id, state: "green"
    assert_run_file current_pipeline_run(id), "test/check.sh", fixture("factory/question-check.sh")
  end

  test "revising an answering shaper's test change still withholds it from the worker until approval" do
    pipeline_factory steps: ["work"]
    id, answer = pipeline_answer_review
    agent_plays({ writes: { "test/check.sh" => fixture("factory/question-check-revised.sh"), ".farmy/answer.md" => "Use resolved with the reviewed test.\n" } })

    factory_revise answer, "Explain the second failure more clearly."

    assert_exit 2
    assert_agent_count 3
    pipeline_status id
    assert_pipeline_status id, state: "awaiting_review", profile: "shape"
    assert_answer_reference_is_question id, current_pipeline_run(id), revision: true
  end

  test "an answering shaper's forbidden source edit is a permission violation and stops automatic continuation" do
    pipeline_factory steps: ["work"], shape: { hidden: [] }
    agent_plays({ writes: { ".farmy/question.md" => "Which greeting?\n" } },
                { writes: { "src/app.txt" => "fixed\n", ".farmy/answer.md" => "Use fixed.\n" } })

    pipeline_start

    assert_exit 1
    assert_stdout "permission_violation"
    assert_agent_count 2
    assert_gate_count 0
    refute_pushed
  end

  test "empty text-only answers end answer_missing without resuming the worker" do
    pipeline_factory steps: ["work"]
    agent_plays({ writes: { ".farmy/question.md" => "Which greeting?\n" } }, { writes: { ".farmy/answer.md" => "  \n" } })

    pipeline_start

    assert_exit 1
    assert_stdout "answer_missing"
    assert_agent_count 2
    refute_pushed
  end

  test "a question from the answering shaper waits for a human instead of recursively dispatching another shaper" do
    pipeline_factory steps: ["work"]
    agent_plays({ writes: { ".farmy/question.md" => "Which greeting?\n" } }, { writes: { ".farmy/question.md" => "Which audience?\n" } })

    id = pipeline_start

    assert_exit 2
    assert_stdout "question"
    assert_agent_count 2
    pipeline_status id
    assert_pipeline_status id, state: "question", handoffs: 1
  end

  test "question and answer control files reach no commit and do not recur during worker continuation" do
    pipeline_factory steps: ["work"]
    agent_plays({ writes: { ".farmy/question.md" => "Which greeting?\n" } },
                { writes: { ".farmy/answer.md" => "Use fixed.\n" } }, { writes: { "src/app.txt" => "fixed\n" } })

    id = pipeline_start

    assert_success
    assert_agent_count 3
    refute_pipeline_control_history id
  end

  test "the default three handoffs permit three answers and refuse the fourth question before another shaper starts" do
    pipeline_factory steps: ["work"]
    answer_cycle_plays 3

    id = pipeline_start

    assert_exit 1
    assert_stdout "handoff_limit"
    assert_agent_count 7
    pipeline_status id
    assert_pipeline_status id, state: "handoff_limit", handoffs: 3
  end

  test "a custom one-handoff budget survives an explicit resume without another answering shaper" do
    pipeline_factory steps: ["work"], handoff_limit: 1
    answer_cycle_plays 1
    id = pipeline_start
    assert_exit 1

    pipeline_resume id

    assert_exit 1
    assert_stdout "handoff_limit"
    assert_agent_count 3
    pipeline_status id
    assert_pipeline_status id, state: "handoff_limit", handoffs: 1
  end

  test "active recovery retains the used handoff budget and rejects the resumed worker's next question before another shaper" do
    pipeline_factory steps: ["work"], handoff_limit: 1
    agent_plays({ writes: { ".farmy/question.md" => "Which greeting is required?\n" } },
                { writes: { ".farmy/answer.md" => "Use fixed.\n" } },
                { barrier: "active-handoff-budget", writes: { ".farmy/question.md" => "May I ask another question?\n" } })
    id = pipeline_start wait: false
    assert_success
    wait_agent_barrier "active-handoff-budget"
    child = current_pipeline_run(id)
    assert_pipeline_status id, handoffs: 1
    interrupt_pipeline_controller id

    pipeline_resume id, wait: false

    assert_success
    assert_pipeline_keeps_child id, child
    assert_agent_count 3
    release_agent_barrier "active-handoff-budget"
    wait_pipeline id, state: "handoff_limit"
    assert_pipeline_status id, handoffs: 1
    assert_agent_count 3
  end

  test "without on_question a pipeline retains the manual question and answer flow" do
    pipeline_factory steps: ["work"], on_question: nil
    agent_plays({ writes: { ".farmy/question.md" => "Which greeting?\n" } })
    id = pipeline_start
    assert_exit 2
    child = current_pipeline_run(id)
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_answer child, "Use fixed."

    assert_success
    wait_pipeline id, state: "green"
  end

  test "the full pipeline shapes pushes revises approves a pinned commit answers a worker question and reaches green" do
    pipeline_factory
    id, shape = pipeline_review
    assert_draft_pushed shape
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check-revised.sh") } })
    factory_revise shape, "Make the failure identify the greeting."
    assert_exit 2
    reviewed = run_id
    remember_gated_commit reviewed
    assert_draft_pushed reviewed, branch: "farmy/shop/#{shape}"
    agent_plays({ writes: { "src/notes.txt" => "Keep this worker note.\n", ".farmy/question.md" => "Which word is the greeting?\n" } },
                { writes: { ".farmy/answer.md" => "The reviewed contract requires fixed.\n" } }, { writes: { "src/app.txt" => "fixed\n" } })

    farmy "factory", "approve", reviewed

    assert_success
    wait_pipeline id, state: "green"
    assert_approved_commit reviewed
    assert_pipeline_work_source id, reviewed
    assert_last_agent_prompt "The reviewed contract requires fixed.", "Which word is the greeting?"
    final = current_pipeline_run(id)
    assert_run_file final, "test/check.sh", fixture("factory/shaped-check-revised.sh")
    assert_run_file final, "src/notes.txt", "Keep this worker note.\n"
    assert_run_file final, "src/app.txt", "fixed\n"
    refute_pipeline_control_history id
    assert_agent_count 5
  end
end
