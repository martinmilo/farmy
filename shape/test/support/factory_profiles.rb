# Named factory profiles and their human handoffs. These helpers prepare repositories and observe
# public commands, the fake Docker's journal, and the branches that are the product of a factory run.
module FactoryProfiles
  def profiled_factory(shape: {}, work: {}, files: {}, commands: {}, model: :api, extra_config: "", check: "grep -q fixed src/app.txt\n")
    common = { "base" => "main", "agent" => "claude", "mode" => "api-key", "test" => "test",
               "max_iterations" => 4, "iteration_timeout" => "30m" }
    profiles = {
      "shape" => common.merge("writes" => ["test/"], "hidden" => ["src/"], "check" => "check", "gate" => "red_first").merge(shape.transform_keys(&:to_s)),
      "work" => common.merge("writes" => ["src/"], "protects" => ["test/"], "gate" => "green").merge(work.transform_keys(&:to_s))
    }
    factory_service profiles: profiles, files: files, check: check, model: model, extra_config: extra_config,
                    commands: { "check" => "sh -n test/check.sh", "release" => "grep -q fixed src/app.txt" }.merge(commands)
  end

  def rename_factory_profiles(shape:, work:)
    definition = YAML.safe_load(read_file("services/shop.yml"))
    profiles = definition.fetch("factory")
    definition["factory"] = { shape => profiles.fetch("shape"), work => profiles.fetch("work") }
    write_file "services/shop.yml", YAML.dump(definition)
  end

  # A source run for tests of approval, chaining or pruning, not a simulated farmy result.
  def shape_run_awaiting_review
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } })
    factory_start profile: "shape", task: "Describe the fixed output in a failing test."
    assert_exit 1
    assert_stdout "awaiting_review"
    id = run_id
    assert id, "Expected a run ID for the shape run awaiting review.#{transcript}"
    note_situation "Shape run #{id} is awaiting review after adding a checked, failing test."
    id
  end

  def approved_shape_run
    id = shape_run_awaiting_review
    farmy "factory", "approve", id
    assert_success
    assert_stdout "green"
    note_situation "Shape run #{id} was approved. Its test expects src/app.txt to say fixed."
    id
  end

  def factory_source(id, as:) = as == :branch ? "farmy/shop/#{id}" : id

  def approved_custom_shape_run
    agent_plays({ writes: { "specs/check.sh" => "grep -q ready lib/greeting.txt\n" } })
    factory_start profile: "describe"
    assert_exit 1
    assert_stdout "awaiting_review"
    id = run_id
    farmy "factory", "approve", id
    assert_success
    id
  end

  def questioned_work_run(writes: {})
    agent_plays({ writes: writes.merge(".farmy/question.md" => "What should src/app.txt say?\n") })
    factory_start profile: "work", task: "Fix the output in src/app.txt."
    assert_exit 1
    assert_stdout "question"
    id = run_id
    assert id, "Expected a run ID for the worker's question.#{transcript}"
    note_situation "Work run #{id} asks what src/app.txt should say."
    id
  end

  def factory_answer(id, text, wait: true)
    farmy "factory", "answer", id, text, *(wait ? ["--wait"] : [])
    (@run_ids ||= []) << run_id if run_id
  end

  def assert_agent_count(count)
    actual = run_containers("agent").size
    assert_equal count, actual, "Expected #{count} agent invocation(s); got #{actual}.#{transcript}"
  end

  def assert_gate_count(count)
    actual = run_containers("test").size
    assert_equal count, actual, "Expected #{count} gate container(s); got #{actual}.#{transcript}"
  end

  def assert_last_agent_prompt(*parts)
    prompt = agent_prompts.last.to_s
    parts.each { |part| assert_includes prompt, part, "Expected the agent prompt to contain #{part.inspect}; it was:\n#{prompt}.#{transcript}" }
  end

  def assert_last_agent_command(part)
    command = run_containers("agent").last&.fetch("process", [])&.join(" ").to_s
    assert_includes command, part, "Expected the selected profile's agent command to include #{part.inspect}; got #{command.inspect}.#{transcript}"
  end

  def assert_run_status(id, **expected)
    runs = service_json("shop").fetch("runs", [])
    run = runs.find { |r| r["id"] == id }
    assert run, "Expected run #{id} in status --json.#{transcript}"
    expected.each do |key, value|
      message = "Expected run #{id}'s #{key} to be #{value.inspect}; got #{run.inspect}.#{transcript}"
      value.nil? ? assert_nil(run[key.to_s], message) : assert_equal(value, run[key.to_s], message)
    end
  end

  def assert_run_file(id, path, text)
    actual = run_file(id, path)
    assert_equal text, actual, "Expected #{path} at the tip of run #{id} to contain #{text.inspect}.#{transcript}"
  end

  def refute_path_in_run_history(id, path)
    commits = local_git(volume_folder("shop-run-#{id}"), "log", "--all", "--format=%H", "--", path)
    assert commits && commits.empty?, "Expected #{path} in no commit of run #{id}; commits mentioning it: #{commits.inspect}.#{transcript}"
  end

  def refute_branch_pushed(id)
    branches = host_git("branch", "--format=%(refname:short)").to_s.split
    refute_includes branches, "farmy/shop/#{id}", "Expected run #{id} not to be published.#{transcript}"
  end

  def assert_continues_run(id, source)
    run_dir = volume_folder("shop-run-#{id}")
    source_sha = local_git(volume_folder("shop-run-#{source}"), "rev-parse", "HEAD").to_s.strip
    ancestor = local_git(run_dir, "merge-base", "HEAD", source_sha).to_s.strip
    assert_equal source_sha, ancestor, "Expected new run #{id} to descend from questioned run #{source}.#{transcript}"
    refute_equal source, id, "Expected an answer to create a new run ID.#{transcript}"
  end
end
