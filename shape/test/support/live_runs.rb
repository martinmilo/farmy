# A control container that factory runs are live in, and what the shim does to it (record 2026-10-26-2126).
#
#   control_container_up                         the control container, made by the shim's init in this folder
#   control_container_for_another_folder         the control container, made by the shim's init in another containers
#                                                folder (it mounts that folder, not this one)
#   control_container_runs_farmy "0.1.0"         the control container's image says it is that farmy (farmy.version)
#   assert_control_container_runs_farmy SHIPPED   its image is labelled farmy.version=that version
#   control_image_out_of_date                    the control image was built from other inputs than this farmy's (farmy.hash)
#   factory_run_live "shop", "20261026-091500-3f9c"   a run live in the control container: docker top of the control
#                                                container lists its controller, `/usr/local/bin/farmy factory run <id>`,
#                                                and its agent container <name>-run-<id>-agent-1 (farmy.run=<id>,
#                                                farmy.role=agent) runs
#   control_container_inspect "error" | "empty"  from now on docker inspect of the control container fails as a daemon
#                                                that does not answer in time does, or answers nothing (exit 0)
#
#   assert_refused_keeping_live_run "<id>"       exit 1, stderr names the run, and the refusal left everything as it was:
#                                                the control container kept, the run live, nothing handed to the container
#   assert_stderr_names_the_other_folder         stderr names the folder control_container_for_another_folder made it in
#   assert_control_container_kept                the control container from before the command still runs: never
#                                                stopped, removed or made anew
#   assert_control_container_made_anew_for_this_folder
#   assert_run_still_live "<id>"                 its controller still listed in that control container, its agent running
#   assert_ran_in_control_container "farmy stop" the command was handed to the control container (docker exec)
#
# Record 2026-10-29-1215: the session counts as a live run, and a folder switch never replaces a container with any.
#   session_live                                 the session is live in the control container: docker top lists its
#                                                tmux server (`tmux new-session -d -s farmy …`) and `farmy tui`
#   control_container_for_the_default_home       the control container, made by the shim's status on this machine with
#                                                no folder named and no farmy.yml: it serves ~/.config/farmy
#   the_other_folder                             the folder control_container_for_another_folder made it in
#   assert_refused_for_the_folder "~/.config/farmy", live: 2   exit 1, one line on stderr naming that folder, "2 live
#                                                runs", the two ways out; the container kept, nothing handed to it
#   assert_session_still_live                    its tmux server still listed in the control container from before
#
# Record 2026-10-29-1530 (a review against real Docker):
#   control_container_removed_by_hand            `docker rm -f farmy`, as troubleshooting says: the container is gone,
#                                                the farmy network it was on is still there (so `docker inspect farmy`
#                                                with no --type finds that network, and a template naming .Config fails)
#   docker_top_fails                             from now on `docker top farmy` fails as a daemon that does not answer
#                                                in time does; the container is there and running
#   assert_refused_unable_to_count(shown)        exit 1, stderr names the daemon's error and `farmy -C <shown>` (when a
#                                                folder is given), the container kept and nothing handed to it
#
# Record 2026-10-29-1800 (read-only commands, one maker at a time, an unreadable container):
#   assert_ran_on_its_own_for_this_folder "farmy status"   the command ran in a container of its own (docker run --rm of
#                                                the control container's image, the command's words in it), which
#                                                mounts this folder at its own path, as the user farmy runs as; nothing
#                                                was handed to the control container
#   control_container_stopped                    the control container is there, stopped (docker stop farmy)
#   assert_refused_unreadable "context deadline exceeded"   exit 1, stderr names the control container and that text,
#                                                the container kept and nothing handed to it
#   control_container_made_slowly                from now on making a container named farmy stays under way until another
#                                                docker call goes to remove or make one (rm, run, create), or 5 s pass; one made by another call meanwhile
#                                                makes it fail with Docker's name conflict
#   two_terminals_at_once "status"               the shim twice, the second started while the first is making the control
#                                                container (its docker run/create --name farmy is under way); both waited for
#   a_shim_killed_while_making_the_control_container   the shim, killed (with what it started) while its docker run of the
#                                                control container is under way
#   assert_both_terminals_succeeded · assert_control_container_made_once · assert_ran_in_control_container_times "farmy status", 2
module LiveRuns
  CONTROL = "farmy"

  def control_container_up
    shim "init"
    assert_success
    mark_control_container
    note_situation "The control container is up, made by the shim's init in this containers folder."
  end

  def control_container_for_another_folder
    folder = the_other_folder
    out, status = Open3.capture2e(Workspace::GIT_ENV.merge(farmy_env).merge("FARMY_DIR" => folder), Target.path("farmy"), "init", chdir: folder) # the kit names the test folder in FARMY_DIR
    raise "the shim's init in another containers folder (#{folder}) failed while preparing the test:\n#{out}" unless status.success?
    mark_control_container
    note_situation "The control container was made by the shim's `farmy init` in another containers folder, #{folder}: it mounts that folder, not this one."
  end

  def control_container_runs_farmy(version)
    change_control_image("farmy.version", version)
    note_situation "The control container runs farmy #{version}: its image is labelled farmy.version=#{version}. This farmy (the shim) is #{Distribution::SHIPPED}."
  end

  def assert_control_container_runs_farmy(version)
    c = container(CONTROL)
    label = c && docker_state["images"].dig(c["image"], "labels", "farmy.version")
    assert label == version, "Expected the control container to run farmy #{version} (its image labelled farmy.version=#{version}); " \
                             "#{c ? "its image #{c["image"]} is labelled #{label.inspect}" : "there is none"}.\n\n#{docker_situation}#{transcript}"
  end

  def control_image_out_of_date
    change_control_image("farmy.hash", "9b1c-of-an-older-build")
    note_situation "The control container's image was built from other inputs than this farmy's: it is labelled farmy.hash=9b1c-of-an-older-build."
  end

  def factory_run_live(service, id)
    agent = "#{service}-run-#{id}-agent-1"
    command = ["sh", "-c", "claude -p --dangerously-skip-permissions \"$1\""]
    change_docker_state do |s|
      control = s["containers"][CONTROL] or flunk("Expected the control container to be up before a run is made live in it.\n\n#{docker_situation}")
      (control["processes"] ||= []) << "/usr/local/bin/farmy factory run #{id}"
      s["containers"][agent] = {
        "project" => nil, "service" => nil, "image" => "farmy/#{service}:dev", "command" => command, "state" => "running",
        "labels" => { "farmy.run" => id, "farmy.service" => service, "farmy.role" => "agent", "farmy.iteration" => "1" },
        "ports" => [], "env" => {}, "init" => false, "volumes" => [{ "name" => "#{service}-run-#{id}", "target" => "/workspace" }],
        "binds" => [], "networks" => ["#{service}-run-#{id}"], "workdir" => "/workspace", "started_seq" => (s["seq"] = s["seq"].to_i + 1),
        "compose_file" => nil, "process" => command, "aliases" => [], "rm" => true
      }
    end
    mark_control_container
    note_situation "Factory run #{id} of #{service} is live in the control container: `docker top #{CONTROL}` lists its controller, " \
                   "`/usr/local/bin/farmy factory run #{id}`, and its agent container #{agent} (labels farmy.run=#{id}, " \
                   "farmy.service=#{service}, farmy.role=agent) is running."
  end

  def control_container_inspect(how)
    change_docker_state { |s| (s["inspect_fails"] ||= {})[CONTROL] = how }
    note_situation(how == "error" ? "docker inspect #{CONTROL} fails from now on, as a daemon that does not answer in time does: " \
                                    "`Error response from daemon: context deadline exceeded`, exit 1. The container is there and running."
                                  : "docker inspect #{CONTROL} answers nothing from now on (exit 0, no output). The container is there and running.")
  end

  def assert_refused_keeping_live_run(id)
    assert_exit 1
    assert_stderr id
    assert_control_container_kept
    assert_run_still_live id
    handed = control_execs_since_mark
    assert handed.empty?, "Expected the refused command not to have been handed to the control container; it ran there: " \
                          "#{handed.map { |e| Shellwords.join(e["command"]) }.join("; ")}.\n\n#{docker_situation}#{transcript}"
  end

  def assert_stderr_names_the_other_folder = assert_stderr(the_other_folder)

  def assert_control_container_kept
    c = container(CONTROL)
    touched = control_calls_since_mark.select { |words| control_ended_by?(words) || control_made_by?(words) }
    now = if c.nil? then "There is no control container now."
          elsif !c["staged"] then "The control container now is another one, made by the command."
          elsif c["state"] != "running" then "It is #{c["state"]}."
          else ""
          end
    asked = touched.empty? ? "" : " The command asked Docker: #{touched.map { |w| "docker #{Shellwords.join(w)}" }.join("; ")}."
    assert now.empty? && touched.empty?, "Expected the control container from before the command to be kept: still running, never " \
                                         "stopped, removed or made anew. #{now}#{asked}\n\n#{docker_situation}#{transcript}"
  end

  def assert_control_container_made_anew_for_this_folder
    c = container(CONTROL)
    now = c.nil? ? "there is none" : c["staged"] ? "it is still the one from before" : "it is #{c["state"]}"
    assert c && !c["staged"] && c["state"] == "running", "Expected the control container to have been made anew by the command " \
                                                         "(the one from before removed, another made and running); #{now}.\n\n#{docker_situation}#{transcript}"
    assert_binds CONTROL, dir, at: dir
  end

  def assert_run_still_live(id)
    c = container(CONTROL)
    listed = c && c["staged"] && Array(c["processes"]).any? { |p| p.include?("factory run #{id}") }
    agent = docker_state["containers"].values.find { |x| x["labels"]["farmy.run"] == id && x["labels"]["farmy.role"] == "agent" }
    gone = [("its controller is gone with the control container from before" unless listed),
            ("its agent container is #{agent ? agent["state"] : "gone"}" unless agent && agent["state"] == "running")].compact
    assert gone.empty?, "Expected factory run #{id} to be live still: its controller `/usr/local/bin/farmy factory run #{id}` in the " \
                        "control container from before, its agent container running. Instead #{gone.join(", and ")}.\n\n#{docker_situation}#{transcript}"
  end

  def session_live
    change_docker_state do |s|
      control = s["containers"][CONTROL] or flunk("Expected the control container to be up before a session is made live in it.\n\n#{docker_situation}")
      (control["processes"] ||= []).push("tmux new-session -d -s farmy -n farmy /usr/local/bin/farmy tui", "/usr/local/bin/farmy tui")
    end
    mark_control_container
    note_situation "The session is live in the control container: `docker top #{CONTROL}` lists its tmux server " \
                   "(`tmux new-session -d -s farmy -n farmy /usr/local/bin/farmy tui`) and `/usr/local/bin/farmy tui`."
  end

  def control_container_for_the_default_home
    env = Workspace::GIT_ENV.merge(farmy_env).merge("FARMY_DIR" => nil)
    out, status = Open3.capture2e(env, Target.path("farmy"), "status", chdir: home)
    raise "the shim's status with no folder named (#{home}) failed while preparing the test:\n#{out}" unless status.success?
    mark_control_container
    note_situation "The control container was made by the shim's `farmy status` run in #{home} with no folder named and no " \
                   "farmy.yml: it serves the default home, ~/.config/farmy (#{machine_path("~/.config/farmy")})."
  end

  # The one line a folder switch is refused with; `shown` is the folder as messages write it (~/… under the home).
  def assert_refused_for_the_folder(shown, live:)
    assert_exit 1
    lines = stderr.lines.map(&:strip).reject(&:empty?)
    assert lines.size == 1, "Expected the refusal to be one line on stderr; it is #{lines.size}:\n    #{lines.join("\n    ")}#{transcript}"
    count = "#{live} live run#{"s" unless live == 1}"
    [shown, count, "finish or cancel them", "farmy -C #{shown}"].each do |part|
      assert lines.first.to_s.include?(part), "Expected the refusal to name #{part.inspect}: the folder the control container " \
                                              "serves, how many live runs it has (#{count}), and the two ways out (finish or cancel " \
                                              "them; or farmy -C #{shown}). It reads: #{lines.first.inspect}#{transcript}"
    end
    assert_control_container_kept
    handed = control_execs_since_mark
    assert handed.empty?, "Expected the refused command not to have been handed to the control container; it ran there: " \
                          "#{handed.map { |e| Shellwords.join(e["command"]) }.join("; ")}.\n\n#{docker_situation}#{transcript}"
  end

  def control_container_removed_by_hand
    change_docker_state do |s|
      s["containers"].delete(CONTROL) or flunk("Expected the control container to be up before it is removed.\n\n#{docker_situation}")
      s["networks"].key?(CONTROL) or flunk("Expected the shim to have made the #{CONTROL} network with the control container; there is none.\n\n#{docker_situation}")
    end
    note_situation "The control container was removed by hand (`docker rm -f #{CONTROL}`, as docs/troubleshooting.md says). The " \
                   "#{CONTROL} network it was on is still there, so `docker inspect #{CONTROL}` with no --type finds that network, " \
                   "and a template that names .Config, .State or .Mounts fails on it: `Template parsing error: … map has no entry " \
                   "for key \"Config\"`, exit 1. `docker container inspect #{CONTROL}` says `No such container`."
  end

  def docker_top_fails
    change_docker_state { |s| (s["top_fails"] ||= []) << CONTROL }
    note_situation "From now on `docker top #{CONTROL}` fails, as a daemon that does not answer in time does: `Error response from " \
                   "daemon: context deadline exceeded`, exit 1. The container is there and running; what runs in it is unknown."
  end

  def assert_refused_unable_to_count(shown = nil)
    assert_exit 1
    ["context deadline exceeded", *("farmy -C #{shown}" if shown)].each do |part|
      assert_includes stderr, part, "Expected the refusal to say why the shim cannot tell whether runs are live in the control container " \
                                    "(the daemon's error, #{"context deadline exceeded".inspect})#{shown ? " and the way out, farmy -C #{shown}" : ""}; " \
                                    "it does not name #{part.inspect}.#{transcript}"
    end
    assert_control_container_kept
    handed = control_execs_since_mark
    assert handed.empty?, "Expected the refused command not to have been handed to the control container; it ran there: " \
                          "#{handed.map { |e| Shellwords.join(e["command"]) }.join("; ")}.\n\n#{docker_situation}#{transcript}"
  end

  def assert_session_still_live
    c = container(CONTROL)
    listed = c && c["staged"] && Array(c["processes"]).any? { |p| p.start_with?("tmux ") }
    assert listed, "Expected the session to be live still: its tmux server in the control container from before. " \
                   "#{c.nil? ? "There is no control container now." : c["staged"] ? "Its tmux server is gone." : "The control container now is another one."}" \
                   "\n\n#{docker_situation}#{transcript}"
  end

  def assert_ran_in_control_container(text)
    hits = control_execs_since_mark.select { |e| ran_text?(e, text) }
    assert !hits.empty?, "Expected the command to have been handed to the control container (`docker exec … #{CONTROL} #{text}`), and it was not.\n\n#{docker_situation}#{transcript}"
  end

  # ── record 2026-10-29-1800 ──

  def assert_ran_on_its_own_for_this_folder(text)
    control = container(CONTROL) or flunk("Expected the control container from before to be there.\n\n#{docker_situation}#{transcript}")
    words = text.split.drop(1) # "farmy status --json" → status --json
    runs = docker_state["runs"].select { |r| r["seq"].to_i > @control_mark_seq.to_i && r["image"] == control["image"] }
    hit = runs.find { |r| Array(r["command"]).each_cons(words.size).include?(words) }
    shown = runs.empty? ? "none" : runs.map { |r| "docker run #{r["image"]} #{Shellwords.join(Array(r["command"]))}" }.join("; ")
    assert hit, "Expected `#{text}` to run in a container of its own for this folder (docker run --rm #{control["image"]} … " \
                "#{text}), since the control container serves another folder and must be kept; runs of the control image " \
                "since the command began: #{shown}.\n\n#{docker_situation}#{transcript}"
    binds = Array(hit["binds"]).map { |b| "#{b["source"]}:#{b["target"]}" }
    assert binds.include?("#{dir}:#{dir}"), "Expected the container `#{text}` ran in to mount this folder, #{dir}, at its own path, as " \
                                            "the control container would; it binds #{binds.empty? ? "nothing" : binds.join(", ")}.#{transcript}"
    if Process.uid != 0
      assert hit["user"].to_s.split(":").first == Process.uid.to_s, "Expected `#{text}` to run as the user farmy runs as (-u #{invoking_user}), " \
                                                                    "as in the control container; it ran as #{hit["user"] || "root (no -u)"}.#{transcript}"
    end
    gone = docker_state["containers"].select { |name, c| c["image"] == control["image"] && name != CONTROL && c["state"] == "running" }
    assert gone.empty?, "Expected the container `#{text}` ran in to be gone when it ended (--rm); still there: #{gone.keys.join(", ")}.\n\n#{docker_situation}#{transcript}"
    handed = control_execs_since_mark
    assert handed.empty?, "Expected nothing to be handed to the control container, which serves another folder; it ran there: " \
                          "#{handed.map { |e| Shellwords.join(e["command"]) }.join("; ")}.\n\n#{docker_situation}#{transcript}"
  end

  def control_container_stopped
    change_docker_state { |s| (s["containers"][CONTROL] or flunk("Expected the control container to be up before it is stopped.\n\n#{docker_situation}"))["state"] = "exited" }
    mark_control_container
    note_situation "The control container is stopped (docker stop #{CONTROL}): no run can be live in it."
  end

  def assert_refused_unreadable(error)
    assert_exit 1
    [error, "control container"].each do |part|
      assert_includes stderr, part, "Expected the command to be refused because the shim cannot read the control container, which says who " \
                                    "farmy runs as in it: stderr names #{part.inspect}.#{transcript}"
    end
    assert_control_container_kept
    handed = control_execs_since_mark
    assert handed.empty?, "Expected the refused command not to have been handed to the control container; it ran there: " \
                          "#{handed.map { |e| "#{Shellwords.join(e["command"])} as #{e["user"] || "root"}" }.join("; ")}.\n\n#{docker_situation}#{transcript}"
  end

  def control_container_made_slowly
    change_docker_state { |s| (s["slow_creates"] ||= {})[CONTROL] = 5 }
    note_situation "Making a container named #{CONTROL} (docker run or create --name #{CONTROL}) stays under way, as a daemon starting it does, " \
                   "until another docker call goes to remove or make a container named #{CONTROL} (docker rm, run or create; a moment after) or 5 s pass. " \
                   "A container of that name made by another call meanwhile makes it fail: `Conflict. The container name \"/#{CONTROL}\" is already in use`."
  end

  def two_terminals_at_once(*args)
    first = spawn_terminal(args)
    under_way = wait_for_control_container_being_made(first)
    second = spawn_terminal(args)
    @terminals = [first, second].map { |t| finish_terminal(t) }
    @finished = Commands::Finished.new("farmy #{args.join(" ")}    (twice: two terminals; the second started #{under_way ? "while the first was making the control container" : "after the first had ended"})",
                                       @terminals.each_with_index.map { |t, i| "── terminal #{i + 1}, exit #{t[:exit]} ──\n#{t[:out]}" }.join("\n"),
                                       "", @terminals.map { |t| t[:exit] }.max_by { |e| e.to_s == "0" ? 0 : 1 }, [*situation])
  end

  def a_shim_killed_while_making_the_control_container
    t = spawn_terminal(["status"])
    under_way = wait_for_control_container_being_made(t)
    Process.kill("KILL", -t[:pid]) rescue nil
    t[:waiter].join(5)
    raise "the first shim ended before it made the control container, so it could not be killed while making it:\n#{File.read(t[:log])}" unless under_way
    note_situation "A shim (`farmy status`) was killed, with what it had started, while its docker run of the control container was under way."
  end

  def assert_both_terminals_succeeded
    failed = @terminals.each_with_index.reject { |t, _| t[:exit] == 0 }
    assert failed.empty?, "Expected both terminals' commands to succeed: the second waits for the first to finish making the control " \
                          "container, then runs its command in it. #{failed.map { |t, i| "Terminal #{i + 1} exited #{t[:exit]}" }.join("; ")}." \
                          "\n\n#{docker_situation}#{transcript}"
  end

  def assert_control_container_made_once
    calls = File.exist?(File.join(docker_journal, "calls.log")) ? File.readlines(File.join(docker_journal, "calls.log"), chomp: true) : []
    words = calls.filter_map { |line| Shellwords.split(line) rescue nil }
    made = words.select { |w| control_made_by?(w) }
    after_made = made.empty? ? [] : words.drop(words.index(made.first) + 1).select { |w| control_ended_by?(w) }
    c = container(CONTROL)
    assert made.size == 1 && after_made.empty? && c && c["state"] == "running",
           "Expected the control container to be made once and then left alone: one docker run (or create) --name #{CONTROL}, and " \
           "nothing removing or stopping it after. It was made #{made.size} time(s)#{after_made.empty? ? "" : ", and then: #{after_made.map { |w| "docker #{Shellwords.join(w)}" }.join("; ")}"}" \
           "; now #{c ? "it is #{c["state"]}" : "there is none"}.\n\n#{docker_situation}#{transcript}"
  end

  def assert_ran_in_control_container_times(text, count)
    hits = docker_state["execs"].select { |e| e["container"] == CONTROL && ran_text?(e, text) }
    assert hits.size == count, "Expected `#{text}` to have been handed to the control container #{count} times (once per terminal); " \
                               "it was #{hits.size} time(s).\n\n#{docker_situation}#{transcript}"
  end

  private

  public def the_other_folder = File.join(scratch, "elsewhere", "containers").tap { |d| FileUtils.mkdir_p(d) }

  def change_control_image(label, value)
    change_docker_state do |s|
      control = s["containers"][CONTROL] or flunk("Expected the control container to be up before its image is changed.\n\n#{docker_situation}")
      s["images"].fetch(control["image"])["labels"][label] = value
    end
    mark_control_container
  end

  def spawn_terminal(args)
    log = File.join(scratch, "terminal-#{(@terminal_count = @terminal_count.to_i + 1)}.log")
    env = Workspace::GIT_ENV.merge(farmy_env).merge(@host_gitconfig ? { "GIT_CONFIG_GLOBAL" => @host_gitconfig } : {})
    pid = Process.spawn(env.transform_values { |v| v&.to_s }, Target.path("farmy"), *args, chdir: dir, pgroup: true, in: File::NULL, out: log, err: [:child, :out])
    { pid: pid, waiter: Process.detach(pid), log: log }
  end

  # true once the shim's docker run/create --name farmy shows in the journal, false when the shim ended first
  def wait_for_control_container_being_made(t)
    calls = File.join(docker_journal, "calls.log")
    deadline = Time.now + Commands::COMMAND_TIMEOUT
    until Time.now > deadline
      lines = File.exist?(calls) ? File.readlines(calls, chomp: true) : []
      return true if lines.any? { |l| control_made_by?(Shellwords.split(l)) rescue false }
      return false unless t[:waiter].alive?
      sleep 0.02
    end
    false
  end

  def finish_terminal(t)
    unless t[:waiter].join(Commands::COMMAND_TIMEOUT)
      Process.kill("KILL", -t[:pid]) rescue nil
      t[:waiter].join(5)
      return { exit: "none (still running after #{Commands::COMMAND_TIMEOUT} s, stopped: it waited and never went on)", out: File.read(t[:log]).scrub }
    end
    status = t[:waiter].value
    { exit: status.exitstatus || "none (killed by signal #{status.termsig})", out: File.read(t[:log]).scrub }
  end

  # The control container as it is now is the one from before the command; later docker calls are the command's.
  def mark_control_container
    change_docker_state do |s|
      (s["containers"][CONTROL] or flunk("Expected a control container named #{CONTROL} while preparing the test.\n\n#{docker_situation}"))["staged"] = true
      @control_mark_seq = s["seq"].to_i
    end
    calls = File.join(docker_journal, "calls.log")
    @control_mark_call = File.exist?(calls) ? File.readlines(calls).size : 0
  end

  def control_execs_since_mark
    docker_state["execs"].select { |e| e["container"] == CONTROL && e["seq"].to_i > @control_mark_seq.to_i }
  end

  def control_calls_since_mark
    calls = File.join(docker_journal, "calls.log")
    return [] unless File.exist?(calls)
    File.readlines(calls, chomp: true).drop(@control_mark_call.to_i).filter_map { |line| Shellwords.split(line) rescue nil }
  end

  def control_ended_by?(words)
    words = words.drop(1) if words.first == "container"
    %w[rm stop kill restart].include?(words.first) && words.drop(1).include?(CONTROL)
  end

  def control_made_by?(words)
    words = words.drop(1) if words.first == "container"
    %w[run create].include?(words.first) && (words.each_cons(2).any? { |a, b| a == "--name" && b == CONTROL } || words.include?("--name=#{CONTROL}"))
  end
end
