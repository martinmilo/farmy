# The run record: per iteration, what the agent ran (command, environment, image), its exit code and
# timing, its prompt, and what it printed on stdout and stderr apart; per run, the agent entry it used and
# its CLI's version. factory_service sets up shop (its check passes once src/app.txt says fixed), Claude in
# api-key mode unless the test says otherwise; the agent does what agent_plays says.
class FactoryRunRecordTest < AcceptanceTest
  test "each iteration's agent record names the service image and its id, the agent's exit code, and when it started and ended" do
    factory_service max_iterations: 2
    agent_plays({ writes: { "src/app.txt" => "almost\n" }, exit: 3 }, { writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_success
    assert_equal [3, 0], [agent_record(1)["exit"], agent_record(2)["exit"]]
    assert_equal ["farmy/shop:dev", image_id_of("farmy/shop:dev")], agent_record(1).values_at("image", "image_id")
    assert_utc_timestamp agent_record(1)["started"], "iteration 1's started"
    assert_utc_timestamp agent_record(1)["ended"], "iteration 1's ended"
  end

  test "the agent's stdout and stderr are kept apart, each exactly as it was printed, and the record names both files" do
    factory_service max_iterations: 1
    agent_plays({ writes: { "src/app.txt" => "fixed\n" }, says: "{\"type\":\"result\",\"usage\":{\"input_tokens\":1200,\"output_tokens\":340}}\n", stderr: "warning: a newer version is available\n" })

    factory_start

    assert_equal "{\"type\":\"result\",\"usage\":{\"input_tokens\":1200,\"output_tokens\":340}}\n", run_record_text("iteration-1.agent.stdout")
    assert_equal "warning: a newer version is available\n", run_record_text("iteration-1.agent.stderr")
    assert_equal ["iteration-1.agent.stdout", "iteration-1.agent.stderr"], agent_record(1).values_at("stdout", "stderr")
  end

  test "the prompt each iteration was given is saved beside its record, exactly" do
    factory_service max_iterations: 2
    agent_plays({ writes: { "src/app.txt" => "almost\n" } }, { writes: { "src/app.txt" => "fixed\n" } })

    factory_start task: "Fix the greeting in src/app.txt."

    assert_equal agent_prompts[0], run_record_text("iteration-1.prompt.md")
    assert_equal agent_prompts[1], run_record_text("iteration-2.prompt.md")
    assert_equal "iteration-2.prompt.md", agent_record(2)["prompt"]
  end

  test "the recorded command is exactly the docker run farmy made for the agent, it never holds the token's value, and the record's environment gives the token as its name" do
    factory_service model: :token, max_iterations: 1
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_recorded_command_is_exactly_the_agents_docker_call 1
    refute agent_record(1)["command"].any? { |word| word.include?("sk-ant-oat01-9f2c") }, "Expected the recorded command without the token's value."
    assert_equal "<CLAUDE_CODE_OAUTH_TOKEN>", agent_record(1)["env"]["CLAUDE_CODE_OAUTH_TOKEN"]
    refute_in_run_folder "sk-ant-oat01-9f2c"
  end

  test "a run keeps the agent entry it used, with its farmy.yml overrides, next to its profile" do
    factory_service max_iterations: 1, extra_config: "agents:\n  claude:\n    headless: {command: claude -p --model claude-opus-5-5 --dangerously-skip-permissions, prompt: argument}\n    env: {CLAUDE_CODE_EFFORT_LEVEL: high}\n"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_equal "claude", run_agent_config["name"]
    assert_equal "claude -p --model claude-opus-5-5 --dangerously-skip-permissions", run_agent_config["headless"]["command"]
    assert_equal({ "CLAUDE_CODE_EFFORT_LEVEL" => "high" }, run_agent_config["env"])
    assert_equal "claude setup-token", run_agent_config["headless_login"]
    assert run_state.key?("profile_config"), "Expected state.json to keep profile_config beside agent_config."
  end

  test "the CLI's version is asked once per run, in the service image, without a network, by the catalogue's version command, and the run keeps what it printed" do
    factory_service max_iterations: 2
    agent_version_prints "2.1.40 (Claude Code)"
    agent_plays({ writes: { "src/app.txt" => "almost\n" } }, { writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_version_asked_once_with "claude --version"
    assert_equal "2.1.40 (Claude Code)", run_state["agent_version"]
  end

  test "an agent of your own may give a version command, and the run keeps what it printed" do
    factory_service agent: "mytool", model: :token, max_iterations: 1, extra_config: mytool_agent(version: "mytool --version")
    agent_version_prints "mytool 2.4.0"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_success
    assert_version_asked_once_with "mytool --version"
    assert_equal "mytool 2.4.0", run_state["agent_version"]
  end

  test "an agent without a version command runs as before, and its run keeps no version" do
    factory_service agent: "mytool", model: :token, max_iterations: 1, extra_config: mytool_agent
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_success
    assert_empty run_containers("version")
    assert_run_keeps_no_version
  end

  test "a version command that fails does not stop the run; the run keeps agent_version unknown and a reason with its exit code and what it said on stderr" do
    factory_service max_iterations: 1
    agent_version_fails
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_success
    assert_stdout "green"
    assert_version_unknown_because "127", "claude: not found"
  end

  test "a CLI that dev may not execute is recorded as agent_version unknown with the reason, Permission denied and its exit code" do
    factory_service max_iterations: 1
    agent_version_denied
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_version_unknown_because "126", "claude: Permission denied"
  end

  test "a version command that gives no answer within 30 s is given up: the run keeps agent_version unknown with the reason, and goes on" do
    factory_service max_iterations: 1
    agent_version_hangs
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })
    factory_start wait: false
    id = run_id

    wait_run id, result: "green", within: 100

    farmy "factory", "show", id
    assert_equal "unknown", run_state["agent_version"], "Expected agent_version \"unknown\" in state.json once the version command had no answer within 30 s.#{transcript}"
    assert_includes run_state["agent_version_reason"].to_s, "30 s", "Expected agent_version_reason in state.json to say the version command gave no answer within 30 s; it is #{run_state["agent_version_reason"].inspect}.#{transcript}"
    refute_running "shop-run-#{id}-version"
  end
end
