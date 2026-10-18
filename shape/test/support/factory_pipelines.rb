# Pipeline vocabulary: all decisions stay in farmy. The helpers prepare profiles, play agents,
# inspect public status and the resulting Git commits, and hold real subprocesses at fake barriers.
module FactoryPipelines
  def pipeline_factory(steps: %w[shape work], on_question: "shape", handoff_limit: nil, review_answers: nil,
                       concurrency: nil, shape: {}, work: {}, files: {}, commands: {}, check: nil)
    options = { shape: shape, work: work, files: files, commands: commands }
    options[:check] = check if check
    profiled_factory(**options)
    pipeline = { "steps" => steps, "on_question" => on_question, "handoff_limit" => handoff_limit,
                 "review_answers" => review_answers }.compact
    change_factory_definition do |definition|
      definition["pipelines"] = { "build" => pipeline }
      definition["factory"]["concurrency"] = concurrency if concurrency
    end
    note_situation "Pipeline build: #{pipeline.inspect}; concurrency #{concurrency || 2}."
  end

  def change_factory_definition
    definition = YAML.safe_load(read_file("services/shop.yml"))
    yield definition
    write_file "services/shop.yml", YAML.dump(definition)
  end

  def pipeline_start(task: "Make the greeting fixed.", name: "build", wait: true)
    farmy "factory", "pipeline", "start", "shop", name, "--task", task, *(wait ? ["--wait"] : [])
    id = pipeline_id
    (@pipeline_ids ||= []) << id if id
    id
  end

  def assert_pipeline_stopped(id, result:)
    pipeline_status id
    assert_pipeline_status id, state: result
    pipeline_runs(id).each do |run|
      refute %w[agent test queued].include?(run["phase"]), "Expected pipeline #{id}'s active and queued children to stop on cancellation.#{transcript}"
    end
  end

  def pipeline_id = (stdout + stderr)[/\bp-\d{8}-\d{6}-[0-9a-f]{4}\b/]

  def run_id = (stdout + stderr)[/(?<![\w-])\d{8}-\d{6}-[0-9a-f]{4}\b/]

  def pipeline_resume(id, wait: true)
    farmy "factory", "pipeline", "resume", id, *(wait ? ["--wait"] : [])
  end

  def pipeline_status(id)
    farmy "status", "--json"
    pipeline_json(id)
  end

  def pipeline_json(id)
    item = Array(service_json("shop")["pipelines"]).find { |p| p["id"] == id }
    assert item, "Expected pipeline #{id} in the service's public status JSON pipelines array.#{transcript}"
    item
  end

  def assert_pipeline_status(id, **expected)
    item = pipeline_json(id)
    expected.each do |key, value|
      assert_equal value, item[key.to_s], "Expected pipeline #{id} #{key}=#{value.inspect}; got #{item.inspect}.#{transcript}"
    end
  end

  def current_pipeline_run(id)
    item = pipeline_status(id)
    run = item["active_run"]
    assert run && run.match?(/\A\d{8}-\d{6}-[0-9a-f]{4}\z/), "Expected pipeline #{id} to expose its preassigned active_run ID before launching its child; got #{item.inspect}.#{transcript}"
    (@run_ids ||= []) << run
    run
  end

  def pipeline_review
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } })
    id = pipeline_start
    assert_exit 2
    assert_stdout "awaiting_review"
    assert id, "Expected pipeline start to print a p- prefixed pipeline ID.#{transcript}"
    [id, current_pipeline_run(id)]
  end

  def shape_run_awaiting_review
    agent_plays({ writes: { "test/check.sh" => fixture("factory/shaped-check.sh") } })
    factory_start profile: "shape", task: "Describe the fixed output in a failing test."
    assert_exit 2
    assert_stdout "awaiting_review"
    id = run_id
    assert id, "Expected a run ID for the shape run awaiting review.#{transcript}"
    id
  end

  def approved_custom_shape_run
    agent_plays({ writes: { "specs/check.sh" => "grep -q ready lib/greeting.txt\n" } })
    factory_start profile: "describe"
    assert_exit 2
    assert_stdout "awaiting_review"
    id = run_id
    farmy "factory", "approve", id
    assert_success
    id
  end

  def questioned_work_run(writes: {})
    agent_plays({ writes: writes.merge(".farmy/question.md" => "What should src/app.txt say?\n") })
    factory_start profile: "work", task: "Fix the output in src/app.txt."
    assert_exit 2
    assert_stdout "question"
    id = run_id
    assert id, "Expected a run ID for the worker's question.#{transcript}"
    id
  end

  def factory_revise(id, feedback, wait: true)
    farmy "factory", "revise", id, feedback, *(wait ? ["--wait"] : [])
    (@run_ids ||= []) << run_id if run_id
  end

  def assert_draft_pushed(id, branch: "farmy/shop/#{id}")
    expected_sha = run_commit(id)
    actual_sha = host_git("rev-parse", "refs/heads/#{branch}").to_s.strip
    assert_equal expected_sha, actual_sha, "Expected awaiting_review run #{id} to publish its exact gated commit to #{branch} immediately.#{transcript}"
  end

  def run_commit(id) = local_git(volume_folder("shop-run-#{id}"), "rev-parse", "HEAD").to_s.strip

  def remember_gated_commit(id)
    @remembered_commits ||= {}
    @remembered_commits[id] = run_commit(id)
    assert_match(/\A[0-9a-f]{40}\z/, @remembered_commits[id], "Expected run #{id} to have a committed gate result.#{transcript}")
  end

  def assert_approved_commit(id)
    farmy "status", "--json"
    expected_sha = @remembered_commits.fetch(id)
    assert_run_status id, approved_commit: expected_sha
  end

  def assert_source_is_remembered_commit(id, source)
    expected_sha = @remembered_commits.fetch(source)
    farmy "status", "--json"
    assert_run_status id, source_commit: expected_sha
    actual = local_git(volume_folder("shop-run-#{id}"), "merge-base", "HEAD", expected_sha).to_s.strip
    assert_equal expected_sha, actual, "Expected run #{id} to descend from the exact approved commit, even when #{source}'s branch has moved.#{transcript}"
  end

  def move_run_branch(id, files: { "test/check.sh" => "exit 0\n" }, publish: true)
    folder = volume_folder("shop-run-#{id}")
    files.each do |path, content|
      FileUtils.mkdir_p(File.dirname(File.join(folder, path)))
      File.write(File.join(folder, path), content)
    end
    remote_git "-C", folder, "add", "."
    remote_git "-C", folder, "commit", "--quiet", "-m", "Unreviewed branch movement"
    remote_git "-C", folder, "push", "--quiet", "origin", "HEAD:refs/heads/farmy/shop/#{id}" if publish
    note_situation "The branch of #{id} advanced after the gate to an unreviewed commit."
  end

  def assert_revision_of(id, source)
    refute_equal source, id, "Expected revise to create a new attempt ID.#{transcript}"
    farmy "status", "--json"
    assert_run_status id, profile: "shape", branch: "farmy/shop/#{source}", result: "awaiting_review"
    assert_run_status source, result: "superseded"
  end

  def assert_profile_snapshot(id, **expected)
    farmy "status", "--json"
    run = service_json("shop").fetch("runs", []).find { |r| r["id"] == id }
    snapshot = run && run["approved_profile"]
    assert snapshot.is_a?(Hash), "Expected approval of #{id} to expose approved_profile, the immutable profile including its gate settings.#{transcript}"
    expected.each { |key, value| assert_equal value, snapshot[key.to_s], "Expected approved_profile #{key} to remain #{value.inspect}.#{transcript}" }
  end

  def assert_gate_snapshot(id, **expected)
    farmy "status", "--json"
    run = service_json("shop").fetch("runs", []).find { |r| r["id"] == id }
    snapshot = run && run["approved_gate"]
    assert snapshot.is_a?(Hash), "Expected approval of #{id} to retain its normalized approved_gate settings.#{transcript}"
    expected.each { |key, value| assert_equal value, snapshot[key.to_s], "Expected approved_gate #{key}=#{value.inspect} after configuration edits.#{transcript}" }
  end

  def change_shape_configuration(check_command: "exit 0")
    change_factory_definition do |definition|
      definition["factory"]["shape"].merge!("writes" => ["specs/"], "gate" => "release", "check" => "different-check")
      definition["commands"]["different-check"] = check_command
    end
  end

  def assert_all_agent_prompts(text)
    agent_prompts.each { |prompt| assert_includes prompt, text, "Expected every pipeline child to retain its original task.#{transcript}" }
  end

  def pipeline_runs(id)
    service_json("shop").fetch("runs", []).select { |run| run["pipeline_id"] == id }
  end

  def assert_pipeline_profiles(id, profiles)
    pipeline_status id
    runs = pipeline_runs(id).sort_by { |run| run["pipeline_step"].to_i }
    assert_equal profiles, runs.map { |run| run["profile"] }, "Expected pipeline #{id} to execute its profiles in order.#{transcript}"
    assert_pipeline_status id, state: "green"
  end

  def refute_factory_run_volumes
    found = docker_state["volumes"].keys.grep(/shop-run-/)
    assert_empty found, "Expected invalid configuration to create no factory run volumes.#{transcript}"
  end

  def remove_review_remote
    remote_git "-C", volume_folder("shop-src"), "remote", "remove", "origin"
    change_factory_definition { |definition| definition["repo"] = "none" }
    note_situation "The developer checkout is a local workbench with no origin remote or repo URL."
  end

  def assert_unpublished_review(id)
    child = current_pipeline_run(id)
    assert_run_status child, result: "publish_failed", compare_url: nil
    assert_pipeline_status id, state: "publish_failed"
  end

  def assert_pipeline_keeps_child(id, child)
    pipeline_status id
    assert_pipeline_status id, active_run: child
    assert_volume "shop-run-#{child}"
  end

  def occupy_factory_slot
    agent_plays({ barrier: "occupied-slot", writes: { "src/app.txt" => "fixed\n" } })
    factory_start profile: "work", wait: false
    assert_success
    wait_agent_barrier "occupied-slot"
  end

  def assert_no_pipeline_profile(id, profile)
    pipeline_status id
    runs = pipeline_runs(id).select { |run| run["profile"] == profile }
    started = runs.select { |run| run_containers("agent").any? { |agent| agent["name"].to_s.include?(run["id"]) } }
    assert_empty started, "Expected no #{profile} agent from invalidated queued downstream work in #{id}.#{transcript}"
  end

  def assert_previous_approval_invalidated(id)
    farmy "status", "--json"
    assert_run_status id, result: "superseded", approval_valid: false
  end

  def pipeline_answer_review
    agent_plays({ writes: { "src/app.txt" => "fixed\n", "src/notes.txt" => "Question work must survive.\n", ".farmy/question.md" => "Resolve the greeting after this change.\n" } },
                { writes: { "test/check.sh" => fixture("factory/question-check.sh"), ".farmy/answer.md" => "Use resolved.\n" } })
    id = pipeline_start
    assert_exit 2
    assert_stdout "awaiting_review"
    [id, current_pipeline_run(id)]
  end

  def assert_answer_reference_is_question(id, answer, revision: false)
    pipeline_status id
    source = pipeline_runs(id).find { |run| run["profile"] == "work" && run["result"] == "question" }
    assert source, "Expected the pipeline to retain the worker run that asked its question.#{transcript}"
    question_sha = run_commit(source["id"])
    assert_run_status answer, red_reference_commit: question_sha
    assert_run_status answer, source_commit: question_sha unless revision
    assert_run_file answer, "src/notes.txt", "Question work must survive.\n"
  end

  def run_file(id, path) = local_git(volume_folder("shop-run-#{id}"), "show", "HEAD:#{path}")

  def refute_pipeline_control_history(id)
    pipeline_status id
    runs = pipeline_runs(id)
    assert !runs.empty?, "Expected pipeline #{id}'s child runs in public status.#{transcript}"
    runs.each do |run|
      refute_path_in_run_history run["id"], ".farmy/question.md"
      refute_path_in_run_history run["id"], ".farmy/answer.md"
    end
  end

  def assert_pipeline_work_source(id, approved)
    pipeline_status id
    worker = pipeline_runs(id).find { |run| run["profile"] == "work" && run["result"] == "question" }
    assert worker, "Expected the first worker's question run in the pipeline history.#{transcript}"
    assert_source_is_remembered_commit worker["id"], approved
  end

  def review_repository(url, forge: nil, web_url: nil)
    change_factory_definition do |definition|
      definition["repo"] = url
      definition["forge"] = forge if forge
      definition["repo_web_url"] = web_url if web_url
    end
    remote_git "-C", volume_folder("shop-src"), "remote", "set-url", "origin", url
    remote_git "config", "--file", File.join(docker_journal, "git-remotes.config"), "--add", "url.#{remote_url('acme/shop')}.insteadOf", url
    note_situation "The repository's origin is #{url}; fake Git transport maps that URL to the local fixture host without internet access."
  end

  def assert_compare_link(id, prefix:)
    farmy "status", "--json"
    run = service_json("shop").fetch("runs", []).find { |r| r["id"] == id }
    link = run && run["compare_url"]
    base = host_git("rev-parse", "main").to_s.strip
    head = run_commit(id)
    assert_equal "#{prefix}#{base}...#{head}", link, "Expected run #{id}'s compare_url to compare immutable base and gated commits.#{transcript}"
    farmy "factory", "show", id
    assert_stdout link
  end

  def refuse_draft_push
    hook = File.join(remote_dir, "acme/shop.git/hooks/pre-receive")
    File.write(hook, "#!/bin/sh\nprintf '%s\\n' 'release mirror is temporarily read-only' >&2\nexit 1\n")
    File.chmod(0o755, hook)
  end

  def accept_draft_push = FileUtils.rm_f(File.join(remote_dir, "acme/shop.git/hooks/pre-receive"))

  def answer_cycle_plays(count)
    plays = count.times.flat_map do |index|
      [{ writes: { "src/notes.txt" => "question #{index + 1}\n", ".farmy/question.md" => "Which greeting, round #{index + 1}?\n" } },
       { writes: { ".farmy/answer.md" => "Use fixed, round #{index + 1}.\n" } }]
    end
    plays << { writes: { ".farmy/question.md" => "One more clarification?\n" } }
    agent_plays(*plays)
  end

  def wait_pipeline(id, state:)
    deadline = Time.now + 45
    loop do
      pipeline_status(id)
      return if pipeline_json(id)["state"] == state
      break if Time.now >= deadline
      sleep 0.05
    end
    assert_pipeline_status id, state: state
  end

  # Polls status until the pipeline is no longer queued or running (45 s at most), whatever state it ends in.
  def wait_pipeline_settled(id)
    deadline = Time.now + 45
    loop do
      break unless %w[queued running].include?(pipeline_status(id)["state"])
      flunk "Expected pipeline #{id} to finish within 45 s; it is still #{pipeline_json(id)["state"]}.#{transcript}" if Time.now >= deadline
      sleep 0.05
    end
  end

  def wait_agent_barrier(name)
    path = File.join(docker_journal, "barriers", "#{name}.entered")
    deadline = Time.now + 45
    sleep 0.05 until File.exist?(path) || Time.now >= deadline
    assert File.exist?(path), "Expected an agent to reach the #{name} barrier.#{transcript}"
  end

  def release_agent_barrier(name)
    folder = File.join(docker_journal, "barriers")
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "#{name}.release"), "released\n")
  end

  # A run's checkout volume, once created, waits before the run clones into it (up to 1 s, or until another process
  # removes it), so any process that cleans the run's resources after launching it does so mid-setup.
  def hold_first_clone
    change_docker_state { |state| state["hold_first_clone"] = true }
    note_situation "Fake Docker holds each run right after it creates its checkout volume, before it clones, up to 1 s or until another process removes that volume."
  end

  # After the run created its checkout volume, only the run itself removes it, and the run's clone succeeded.
  def assert_checkout_left_to_its_run(run)
    volume = "shop-run-#{run}"
    events = Array(docker_state["checkout_events"]).select { |e| e["volume"] == volume }
    log = File.join(dir, ".work/shop/runs", run, "controller.log")
    log_text = File.exist?(log) ? File.read(log).lines.last(5).join.gsub(/^/, "    ") : "    (none)\n"
    last_create = events.rindex { |e| e["op"] == "create" }
    assert last_create, "Expected run #{run} to create its checkout volume #{volume}.\n  Its controller.log ends:\n#{log_text}#{transcript}"
    removed_last = events.rindex { |e| e["op"] == "rm" }
    if removed_last && removed_last > last_create && events[removed_last]["by"] !~ /factory run #{run}/
      flunk "Expected run #{run} to have its checkout volume #{volume} when it set up: #{events[removed_last]["by"]} removed it after the run " \
            "had created it, and the run did not create it again. Preassigned resources must be cleaned before the child launches, never while it sets up.\n" \
            "  Checkout events, in order: #{events.map { |e| "#{e["op"]} by #{e["by"]}" }.join("; ")}\n  Its controller.log ends:\n#{log_text}#{transcript}"
    end
    others = events.drop(last_create + 1).select { |e| e["op"] == "rm" && !e["by"].include?("factory run #{run}") }
    assert_empty others, "Expected nobody but run #{run} to remove its checkout volume #{volume} once the run had created it: preassigned resources " \
                         "must be cleaned before the child launches, never while it sets up. Removed by: #{others.map { |e| e["by"] }.uniq.join(" | ")}.\n" \
                         "  Checkout events, in order: #{events.map { |e| "#{e["op"]} by #{e["by"]}" }.join("; ")}#{transcript}"
    refute_match(/could not clone the checkout/, File.exist?(log) ? File.read(log) : "", "Expected run #{run} to clone its checkout; its controller.log says it could not.#{transcript}")
  end

  # assert_checkout_left_to_its_run for every run this test made (the worker, the answering shaper, the continuation).
  def assert_every_checkout_left_to_its_run
    runs = Dir.exist?(File.join(dir, ".work/shop/runs")) ? Dir.children(File.join(dir, ".work/shop/runs")).sort : []
    runs.each { |run| assert_checkout_left_to_its_run run }
    assert runs.size >= 3, "Expected at least three runs (the question, its answer, the continuation); there are: #{runs.join(", ")}.#{transcript}"
  end

  # The ID of the one run this test made.
  def the_only_run
    runs = Dir.exist?(File.join(dir, ".work/shop/runs")) ? Dir.children(File.join(dir, ".work/shop/runs")).sort : []
    assert_equal 1, runs.size, "Expected exactly one run in .work/shop/runs; there are: #{runs.join(", ")}.#{transcript}"
    runs.first
  end

  def hold_next_checkout_volume(name)
    change_docker_state { |state| state["pipeline_checkout_volume_barrier"] = name }
    note_situation "Fake Docker will pause its next run-checkout volume creation at #{name}, before that create call returns."
  end

  def assert_preassigned_child_at_volume_barrier(id, barrier:)
    wait_agent_barrier barrier
    volume = File.read(File.join(docker_journal, "barriers", "#{barrier}.entered"))
    child = current_pipeline_run(id)
    assert_equal "shop-run-#{child}", volume, "Expected durable public active_run to identify the checkout volume before its creation call returns.#{transcript}"
    assert_agent_count 0
    assert_volume volume
    child
  end

  def crash_incomplete_pipeline(id, child:)
    stop_pipeline_process_tree id, required: true
    folder = File.join(volume_folder("shop-run-#{child}"), "src")
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "incomplete-launch.txt"), "Residue from an interrupted checkout must not reach a resumed run.\n")
    note_situation "Pipeline #{id}'s controller and descendants were killed before its first agent launched; #{child}'s existing checkout volume now contains partial checkout residue."
  end

  def refute_run_file(id, path)
    assert_nil run_file(id, path), "Expected resumed run #{id} to discard incomplete checkout residue #{path}, never commit it.#{transcript}"
  end

  def queue_factory_task(task)
    factory_start profile: "work", task: task, wait: false
    assert_success
    child = run_id
    assert_factory_queued child
    child
  end

  def assert_barrier_run(barrier, child)
    path = File.join(docker_journal, "barriers", "#{barrier}.entered")
    observed = File.read(path)
    assert_includes observed, child, "Expected queued run #{child} to start at #{barrier}, got container #{observed.inspect}.#{transcript}"
  end

  def wait_agent_invocations(count)
    deadline = Time.now + 45
    sleep 0.05 until run_containers("agent").size >= count || Time.now >= deadline
    assert_agent_count count
  end

  def simultaneously(*commands)
    environment = Workspace::GIT_ENV.merge(farmy_env)
    environment["GIT_CONFIG_GLOBAL"] = @host_gitconfig if @host_gitconfig
    running = commands.map do |args|
      input, output, error, waiter = Open3.popen3(environment, Target.path(PROGRAM), *args, chdir: dir, pgroup: true)
      input.close
      [args, output, error, waiter]
    end
    @simultaneous_results = running.map do |args, output, error, waiter|
      out = Thread.new { output.read.scrub }
      err = Thread.new { error.read.scrub }
      unless waiter.join(20)
        Process.kill("KILL", -waiter.pid) rescue nil
        flunk "Expected simultaneous farmy #{args.join(' ')} to return within 20 s."
      end
      Commands::Finished.new("farmy #{args.join(' ')}", out.value, err.value, waiter.value.exitstatus, situation.dup)
    end
    @finished = @simultaneous_results.last
    @run_ids ||= []
    @simultaneous_results.each { |result| @run_ids.concat((result.stdout + result.stderr).scan(/(?<!p-)\b\d{8}-\d{6}-[0-9a-f]{4}\b/)) }
  end

  def assert_simultaneous_success
    @simultaneous_results.each { |result| assert_equal 0, result.exit, "Expected each simultaneous command to be accepted.\n#{result}" }
  end

  def simultaneous_run_ids
    @simultaneous_results.map { |r| (r.stdout + r.stderr)[/\b\d{8}-\d{6}-[0-9a-f]{4}\b/] }
  end

  def interrupt_pipeline_controller(id)
    lines, = Open3.capture2("ps", "-eo", "pid=,args=")
    row = lines.lines.find { |line| line.include?("factory pipeline run #{id}") }
    assert row, "Expected a detached pipeline controller identifiable as factory pipeline run #{id}.#{transcript}"
    pid = row.to_i
    Process.kill("KILL", pid)
    # A crash is over once the process is gone: reap it when it is this test's own child (the subreaper adopts
    # detached controllers), and wait until no such pid remains before anyone resumes the pipeline.
    deadline = Time.now + 10
    loop do
      begin
        Process.waitpid(pid, Process::WNOHANG)
      rescue Errno::ECHILD
        nil
      end
      break unless File.exist?("/proc/#{pid}") || (Process.kill(0, pid) rescue false)
      flunk "Expected pipeline #{id}'s controller (pid #{pid}) to be gone within 10 s of SIGKILL; it is still there.#{transcript}" if Time.now >= deadline
      sleep 0.02
    end
    note_situation "Only pipeline #{id}'s controller (pid #{pid}) was interrupted and is gone; its running child containers and volumes remain."
  end

  def pipeline_process_snapshot
    lines, = Open3.capture2("ps", "-eo", "pid=,ppid=,args=")
    lines.lines.filter_map do |line|
      match = line.match(/\A\s*(\d+)\s+(\d+)\s+(.*)\z/m)
      match && { pid: match[1].to_i, parent: match[2].to_i, command: match[3] }
    end
  end

  def stop_pipeline_process_tree(id, required: false)
    processes = pipeline_process_snapshot
    controller = processes.find { |process| process[:command].match?(/\bfactory pipeline run #{Regexp.escape(id)}(?:\s|\z)/) }
    assert controller, "Expected fixture pipeline controller factory pipeline run #{id} before simulating its crash.#{transcript}" if required
    return unless controller
    root = controller[:pid]
    return if root == Process.pid
    begin
      Process.kill("STOP", root)
    rescue Errno::ESRCH
      return
    end
    processes = pipeline_process_snapshot
    descendants = [root]
    loop do
      added = processes.select { |process| descendants.include?(process[:parent]) }.map { |process| process[:pid] } - descendants
      break if added.empty?
      descendants.concat(added)
    end
    descendants.reverse_each do |pid|
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        # It already finished; only this fixture controller and its observed descendants are targeted.
      end
    end
  end

  def assert_child_identity_precedes_launch(id)
    active = current_pipeline_run(id)
    agents = run_containers("agent").select { |r| r["name"].to_s.include?(active) }
    assert_equal 1, agents.size, "Expected the preassigned active child #{active} to identify exactly one launched agent.#{transcript}"
    assert_volume "shop-run-#{active}"
  end

  def after_teardown
    Array(@pipeline_ids).compact.uniq.each { |id| stop_pipeline_process_tree id }
    super
  end
end
