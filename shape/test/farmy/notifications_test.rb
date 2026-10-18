class NotificationsTest < AcceptanceTest
  test "a shape draft awaiting review posts its pinned comparison link also exposed by show and TUI data" do
    notifying_factory
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } })

    factory_start profile: "shape"

    assert_exit 2
    assert_notification "awaiting_review", profile: "shape"
    assert_notification_matches_public_review
  end

  test "a green run posts JSON identity result commit and a pinned comparison link" do
    notifying_factory
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start profile: "work"

    assert_success
    assert_notification "green"
  end

  test "a pipeline review notification identifies its pipeline and one-based shape step" do
    notifying_factory
    notification_pipeline
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } })

    id = pipeline_start

    assert_exit 2
    assert_notification "awaiting_review", profile: "shape", pipeline_id: id, step: 1
  end

  test "a worker question posts its question transition without its private question text" do
    notifying_factory
    agent_plays({ writes: { ".farmy/question.md" => "Private question: invoice field customer_note-62b4?\n" } })

    factory_start profile: "work"

    assert_exit 2
    assert_notification "question"
    refute_notification_content "customer_note-62b4"
  end

  test "a terminal failure posts failed with the specific run result and its comparison link" do
    notifying_factory work: { max_iterations: 1 }
    agent_plays({ writes: { "src/app.txt" => "still broken\n" } })

    factory_start profile: "work"

    assert_exit 1
    assert_notification "failed", result: "max_iterations"
  end

  test "a notification for a local forge retains the branch fallback with a null comparison URL" do
    notifying_factory compare: false
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start profile: "work"

    assert_success
    assert_notification "green", compare: false
  end

  ["ntfy", "slack"].each do |format|
    test "#{format} receives a readable POST with the run branch result and pinned comparison link" do
      notifying_factory format: format
      agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

      factory_start profile: "work"

      assert_success
      assert_notification_text format, event: "green"
    end
  end

  test "three failed webhook attempts retain one event ID and report failure without changing a green run" do
    notifying_factory receiver_status: 503
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start profile: "work"

    assert_success
    assert_stdout "green"
    assert_stderr(/notif.*(?:fail|undelivered)/i)
    assert_notification_attempts 3, event: "green"
    refute_notification_error_details
  end

  test "show preserves a notification delivery failure after the successful run command has exited" do
    notifying_factory receiver_status: 503
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })
    factory_start profile: "work"
    id = run_id
    assert_notification_attempts 3, event: "green"

    farmy "factory", "show", id

    assert_success
    assert_stdout "green"
    assert_stdout(/notif[^\n]*(?:fail|undelivered)/i)
  end

  test "notification endpoint and bearer token resolve from provider references without entering persisted state" do
    notifying_factory private_endpoint: true
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start profile: "work"

    assert_success
    assert_notification_authorization
    refute_notification_credentials_persisted
  end

  test "failed notification diagnostics never echo the endpoint token headers or receiver body" do
    notifying_factory private_endpoint: true, receiver_status: 503, receiver_body: "receiver-private-body-9b31"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start profile: "work"

    assert_success
    assert_stderr(/notif.*(?:fail|undelivered)/i)
    refute_notification_error_details
    refute_notification_credentials_persisted
  end

  test "notification payloads exclude task text and agent and test output by default" do
    notifying_factory commands: { "test" => "printf 'Gate private log check-95e1\\n'; sh test/check.sh" }
    agent_plays({ writes: { "src/app.txt" => "fixed\n" }, says: "Agent private log ledger-82f1" })

    factory_start profile: "work", task: "Private task: customer note customer-5d70"

    assert_success
    assert_notification "green"
    refute_notification_content "customer-5d70", "ledger-82f1", "check-95e1"
  end

  test "notification payloads exclude an answer used to continue a questioned worker" do
    notifying_factory
    id = questioned_work_run
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_answer id, "Private answer: customer note response-83f2"

    assert_success
    assert_notification "green"
    refute_notification_content "response-83f2", "What should src/app.txt say?"
  end
end
