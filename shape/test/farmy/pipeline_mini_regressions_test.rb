class PipelineMiniRegressionsTest < AcceptanceTest
  %w[shape design].each do |profile|
    test "a pipeline step named #{profile} also serving as on question pauses for a human without a recursive handoff" do
      self_questioning_pipeline profile

      id = pipeline_start

      assert_exit 2
      assert_agent_count 1
      pipeline_status id
      assert_pipeline_status id, state: "question", step: 1, profile: profile, handoffs: 0
    end
  end

  test "a human answer resumes the original questioning shape step and its test still waits for review" do
    id, child = questioned_shape_pipeline
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } })

    factory_answer child, "The greeting must be fixed."

    wait_pipeline id, state: "awaiting_review"
    assert_pipeline_status id, step: 1, profile: "shape", handoffs: 0
    assert_agent_count 2
    assert_last_agent_prompt "Which greeting should the test require?", "The greeting must be fixed."
  end

  %w[run pipeline].each do |view|
    test "#{view} show names actual forbidden edits as dropped without inventing a hidden write blocked by its mount" do
      forbidden_answer_pipeline

      show_permission_violation view

      assert_success
      assert_dropped_paths_reported
      assert_forbidden_changes_dropped
    end
  end

  %w[json ntfy slack].each do |format|
    test "#{format} permission violation notification names dropped paths without private content" do
      forbidden_answer_pipeline notify: format

      assert_permission_notification format
      assert_forbidden_changes_dropped
    end
  end

  %w[awaiting_review question green failed].each do |outcome|
    test "the follow up show command printed for a #{outcome} pipeline accepts its pipeline id" do
      pipeline_outcome outcome
      id = pipeline_start

      follow_printed_pipeline_show id

      assert_success
      assert_stdout id
    end
  end
end
