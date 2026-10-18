module MiniPipelines
  FORBIDDEN_ANSWER_PATHS = %w[docs/guide.md test/protected/contract.sh private/notes.txt].freeze
  CHANGED_ANSWER_PATHS = %w[docs/guide.md test/protected/contract.sh].freeze

  def self_questioning_pipeline(profile = "shape")
    pipeline_factory
    if profile != "shape"
      rename_factory_profiles shape: profile, work: "work"
      change_factory_definition do |definition|
        definition.fetch("pipelines").fetch("build").merge!("steps" => [profile, "work"], "on_question" => profile)
      end
    end
    agent_plays({ writes: { ".farmy/question.md" => "Which greeting should the test require?\n" } })
  end

  def questioned_shape_pipeline
    self_questioning_pipeline
    id = pipeline_start
    assert_exit 2
    assert_stdout "question"
    assert_agent_count 1
    [id, current_pipeline_run(id)]
  end

  def forbidden_answer_pipeline(notify: nil)
    options = {
      shape: { writes: ["test/"], protects: ["test/protected/"], hidden: ["private/"] },
      files: FORBIDDEN_ANSWER_PATHS.to_h { |path| [path, "Keep this original file.\n"] }
    }
    if notify
      notifying_factory(format: notify, **options)
      notification_pipeline
      change_factory_definition { |definition| definition.fetch("pipelines").fetch("build")["steps"] = ["work"] }
    else
      pipeline_factory(steps: ["work"], **options)
    end
    writes = FORBIDDEN_ANSWER_PATHS.to_h { |path| [path, "Unapproved private content forbidden-content-7ac2.\n"] }
    agent_plays({ writes: { ".farmy/question.md" => "Which greeting?\n" } },
      { writes: writes.merge(".farmy/answer.md" => "Use fixed.\n") })
    id = pipeline_start
    assert_exit 1
    assert_stdout "permission_violation"
    assert_agent_count 2
    @violation_pipeline = id
    @violation_run = current_pipeline_run(id)
  end

  def show_permission_violation(view)
    if view == "pipeline"
      farmy "factory", "pipeline", "show", @violation_pipeline
    else
      farmy "factory", "show", @violation_run
    end
  end

  def assert_dropped_paths_reported
    assert_stdout "permission_violation"
    CHANGED_ANSWER_PATHS.each { |path| assert_stdout path }
    refute_stdout "private/notes.txt"
    assert_stdout(/dropped/i)
    refute_stdout "forbidden-content-7ac2"
  end

  def assert_forbidden_changes_dropped
    FORBIDDEN_ANSWER_PATHS.each { |path| assert_run_file @violation_run, path, "Keep this original file.\n" }
    assert_gate_count 0
    refute_pushed
  end

  def assert_permission_notification(format)
    wait_notification_requests 1
    bodies = notification_requests.map { |request| request.fetch("body") }
    body = bodies.find { |text| text.include?("permission_violation") }
    assert body, "Expected a #{format} permission_violation notification, got #{bodies.inspect}.#{transcript}"
    CHANGED_ANSWER_PATHS.each do |path|
      assert_includes body, path, "The #{format} notification must name every actual forbidden path before the edit was dropped.#{transcript}"
    end
    refute_includes body, "private/notes.txt", "A hidden write blocked by the read-only mount never changed this path and must not be invented as a dropped change.#{transcript}"
    assert_match(/dropped/i, body, "The notification must say the forbidden edits were dropped.#{transcript}")
    refute_notification_content "forbidden-content-7ac2", "Which greeting?", "Use fixed."
  end

  def pipeline_outcome(outcome)
    case outcome
    when "question"
      self_questioning_pipeline
    when "awaiting_review"
      pipeline_factory steps: ["shape"]
      agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } })
    when "green"
      pipeline_factory steps: ["work"]
      agent_plays({ writes: { "src/app.txt" => "fixed\n" } })
    when "failed"
      pipeline_factory steps: ["work"], work: { max_iterations: 1 }
      agent_plays({ writes: { "src/app.txt" => "still wrong\n" } })
    end
  end

  def follow_printed_pipeline_show(id)
    command = (stdout + "\n" + stderr)[/farmy factory(?: pipeline)? show #{Regexp.escape(id.to_s)}\b/]
    assert command, "Pausing or ending pipeline #{id} must print a show command that accepts that pipeline ID.#{transcript}"
    farmy(*Shellwords.split(command).drop(1))
  end
end
