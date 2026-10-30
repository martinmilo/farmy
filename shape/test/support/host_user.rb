# Who farmy runs as in the control container, and who owns what it writes (record 2026-10-29-1215).
#
#   invoking_user                                "<uid>:<gid>" of the process that runs the test (the user who runs farmy)
#   shim_on_a_terminal                           the shim with stdin and stdout a terminal (no command: a bare farmy,
#                                                the session); answers "n" when asked [y/N]
#   docker_daemon_is "rootless" | "userns"       docker info lists that security option: container root is the user
#   assert_farmy_ran_as_the_invoking_user        every docker exec of farmy in the control container carried
#                                                -u <uid>:<gid> of the invoking user
#   assert_farmy_ran_as_root                     every one ran as root (no -u, or -u 0 / 0:0 / root)
#   assert_build_files_fetched_as "1000:1000"    every container farmy ran that writes into a service's folder in
#                                                .work (a read-write bind mount under .work/<name>/) ran with --user
#                                                that; none at all is fine (record 2026-10-29-1530)
#
# Record 2026-10-29-1530 (a review against real Docker):
#   the_shim_sees_the_caller uid: 0, gid: 0, why: "root"   `id -u` and `id -g` answer those to the shim from now on
#   docker_info_fails                            from now on every `docker info` asked for a format (-f) fails as a
#                                                daemon that does not answer in time does; a plain `docker info` answers
#   build_files_over_ssh(build_files: ["Gemfile.lock"])   on top of git_containers_behind_mesh: services/toolkit.yml names
#                                                https://git.example.com/acme/toolkit.git, which the git route's
#                                                insteadOf rule sends over ssh; the fake host serves it after the route
#                                                authenticates, and ssh refuses a uid with no account (not root or dev)
#   assert_farmy_ran_as "1000:1000"              every docker exec of farmy in the control container had -u that
#   assert_farmy_ran_as_uid 1000                 every one ran as that uid, whatever the group
#   assert_home_kept_in_a_volume                 the home farmy runs with in the control container (HOME of its
#                                                execs) lies in a named volume mounted into the control container
#
# Record 2026-10-29-1800 (sudo, real-host risks):
#   the_shim_runs_under_sudo_e                   `id -u`/`id -g` answer 0 to the shim; SUDO_UID, SUDO_GID and SUDO_USER
#                                                name the invoking user (the test's own uid and gid); HOME stays theirs
#   the_host_says_root_owns "~/.config/farmy", … `stat` answers 0 (root) as owner and group of those paths and what is
#                                                in them, as after an earlier `sudo -E farmy`; other paths as they are
#   control_container_made_for_root_by_a_root_caller   farmy.yml in this folder, which the host says is root's; the shim,
#                                                run by root, made the control container for it (to run farmy as root);
#                                                the caller is the invoking user again from now on
#   docker_client_warns                          from now on the docker client prints a warning line on stderr at every
#                                                call (its config file unreadable); its answers are as without it
#   any_one_inspect_fails 3                      from now on the 3rd docker inspect of the control container fails as a
#                                                daemon that does not answer in time does; every other one answers
#   assert_ran_as_the_invoking_user_or_refused_naming_the_error   every farmy command handed to the control container
#                                                since then ran as the invoking user; or none was, and the command was
#                                                refused (exit 1) naming the daemon's error
#   assert_handed_back "~/.config/farmy", …      a command run as root in the control container (the one-time hand-back)
#                                                named each of those folders
#   assert_hand_back_names_nothing_in dir, but: ".work"   no command run as root in the control container named that
#                                                folder or anything in it, but what lies in its .work
#
# With a real Docker (IntegrationTest):
#   (record 2026-10-29-1800, these need a root runner to stage root's files, as the Mini's is)
#   real_shim_under_sudo_e "status"              the real shim run by root as `sudo -E` leaves it: HOME the plain user's,
#                                                SUDO_UID, SUDO_GID (4242) and SUDO_USER naming that user
#   default_home_left_root_s                     ~/.config/farmy with farmy.yml and ~/.local/state/farmy/.work, made by
#                                                root (as 43583a9's sudo -E left them); no control container
#   shared_folder_of_root_s                      a containers folder root owns (mode 0777) with root's farmy.yml; no
#                                                control container; returns its path
#   assert_root_s "<path>", …                    each path is root's (0:0)
#   real_session_attached { … }                  a bare farmy through the real shim on a terminal, as a plain user (the
#                                                test's own when it is not root, else uid 4242); answers "n" at [y/N],
#                                                waits for the session's TUI, runs the block while it is still attached
#   real_shim_as_the_user "init"                 the real shim as that same user
#   assert_owned_by_the_user "~/.config/farmy/farmy.yml", …   each path is that user's (uid and gid)
require "pty"
require "shellwords"

module HostUser
  PLAIN_UID = 4242

  def invoking_user = "#{Process.uid}:#{Process.gid}"

  def docker_daemon_is(option)
    change_docker_state { |s| s["daemon_security_options"] = [option.to_s] }
    note_situation "The Docker daemon is #{option == "rootless" ? "rootless" : "remapping users (userns-remap)"}: `docker info` lists " \
                   "name=#{option} under its security options, and root in a container is the user on the host."
  end

  def shim_on_a_terminal(*args, typing: "n")
    line = "farmy #{args.join(" ")}".strip + "    (stdin and stdout are a terminal; typed at [y/N]: #{typing.inspect})"
    remember_workspace
    before = [*situation, *repository_state]
    env = Workspace::GIT_ENV.merge(farmy_env)
    env["GIT_CONFIG_GLOBAL"] = @host_gitconfig if @host_gitconfig
    master, slave = PTY.open
    pid = Process.spawn(env.transform_values { |v| v&.to_s }, Target.path("farmy"), *args, in: slave, out: slave, err: slave, chdir: dir, pgroup: true)
    slave.close
    tty = +""
    reader = Thread.new { loop { tty << master.readpartial(4096) } rescue nil }.tap { |t| t.report_on_exception = false }
    waiter = Process.detach(pid)
    typed = false
    deadline = Time.now + Commands::COMMAND_TIMEOUT
    while waiter.alive? && Time.now < deadline
      if !typed && tty.include?("[y/N]")
        master.write("#{typing}\n")
        typed = true
      end
      sleep 0.02
    end
    if waiter.alive?
      Process.kill("KILL", -pid) rescue nil
      waiter.join
      raise Minitest::Assertion, "The command was still running after #{Commands::COMMAND_TIMEOUT} s and was stopped.\n\n  $ #{line}\n  terminal: #{tty}"
    end
    status = waiter.value
    reader.join(5)
    master.close
    @terminal_output = tty
    @finished = Commands::Finished.new(line, tty.scrub, "", status.exitstatus || "none (killed by signal #{status.termsig})", before)
  end

  def assert_farmy_ran_as_the_invoking_user
    execs = farmy_execs
    refute_empty execs, "Expected the shim to hand farmy to the control container (docker exec … farmy farmy …); it handed nothing.\n\n#{docker_situation}#{transcript}"
    wrong = execs.reject { |e| e["user"] == invoking_user }
    assert wrong.empty?, "Expected every docker exec of farmy in the control container to run as the invoking user (-u #{invoking_user}), " \
                         "so that what farmy writes is that user's from the moment it is written; these ran otherwise:\n    " \
                         "#{wrong.map { |e| "#{shown_exec(e)}  as #{e["user"] || "root (no -u)"}" }.join("\n    ")}#{transcript}"
  end

  def assert_farmy_ran_as_root
    execs = farmy_execs
    refute_empty execs, "Expected the shim to hand farmy to the control container (docker exec … farmy farmy …); it handed nothing.\n\n#{docker_situation}#{transcript}"
    wrong = execs.reject { |e| [nil, "", "0", "0:0", "root", "root:root"].include?(e["user"]) }
    assert wrong.empty?, "Expected every docker exec of farmy in the control container to run as root (no -u, or -u 0): here root in a " \
                         "container is the user on the host; these ran otherwise:\n    #{wrong.map { |e| "#{shown_exec(e)}  as #{e["user"]}" }.join("\n    ")}#{transcript}"
  end

  def assert_build_files_fetched_as(user)
    # raw journal lines: a git container's environment can hold quotes that do not split as shell words
    runs = journal_lines.select { |l| l.match?(/\A(?:container )?(?:run|create) /) && !l.include?("farmy.role=agent") && writes_into_work?(l) }
    runs.each do |line|
      given = line[/(?:\A| )(?:-u|--user)[ =](\S+)/, 1]
      assert given == user, "Expected every container farmy runs that writes into a service's folder in the state folder's .work (here the " \
                            "git container that fetches the build files) to run as the user farmy runs as (--user #{user}), so the files " \
                            "are that user's from the moment they are written, with no chown afterwards; it ran as " \
                            "#{given ? "-u #{given}" : "root (no --user)"}:\n    docker #{line[0, 300]}…#{transcript}"
    end
  end

  def the_shim_sees_the_caller(uid:, gid:, why:)
    id = File.join(store_bin, "id")
    real = %w[/usr/bin/id /bin/id].find { |p| File.executable?(p) }
    File.write(id, "#!/bin/sh\ncase \"$*\" in -u|-ru) echo #{uid} ;; -g|-rg) echo #{gid} ;; *) exec #{real} \"$@\" ;; esac\n")
    File.chmod(0o755, id)
    note_situation "The shim's caller is #{why}: `id -u` says #{uid} and `id -g` says #{gid}."
  end

  def docker_info_fails
    change_docker_state { |s| s["info_format_fails"] = true }
    note_situation "From now on `docker info` asked for a format (-f '{{…}}') fails, as a daemon that does not answer in time does: " \
                   "`Error response from daemon: context deadline exceeded`, exit 1. A plain `docker info` still answers."
  end

  def build_files_over_ssh(build_files: nil)
    remote = remote_url("acme/toolkit")
    write_file "services/toolkit.yml", YAML.dump({ "repo" => "https://git.example.com/acme/toolkit.git", "dockerfile" => "Dockerfile", "target" => "base",
                                              **(build_files ? { "build_files" => build_files } : {}) })
    change_docker_state do |state|
      route = state["git_hosts"]["https://git.example.com/dev/dotfiles.git"]
      state["git_hosts"]["https://git.example.com/acme/toolkit.git"] =
        route.merge("local_url" => remote, "aliases" => ["ssh://git@git.example.com/acme/toolkit.git"])
    end
    note_situation "services/toolkit.yml names https://git.example.com/acme/toolkit.git: the git route's insteadOf rule sends it over ssh, " \
                   "and the fake host serves it (acme/toolkit with its Dockerfile) once the route authenticates. ssh refuses to run as a " \
                   "uid the image has no account for (only root and dev, 1001): `No user exists for uid <n>`."
  end

  def assert_farmy_ran_as(user)
    execs = farmy_execs
    refute_empty execs, "Expected the shim to hand farmy to the control container (docker exec … farmy farmy …); it handed nothing.\n\n#{docker_situation}#{transcript}"
    wrong = execs.reject { |e| e["user"] == user }
    assert wrong.empty?, "Expected every docker exec of farmy in the control container to run as #{user} (-u #{user}); these ran " \
                         "otherwise:\n    #{wrong.map { |e| "#{shown_exec(e)}  as #{e["user"] || "root (no -u)"}" }.join("\n    ")}#{transcript}"
  end

  def assert_farmy_ran_as_uid(uid)
    execs = farmy_execs
    refute_empty execs, "Expected the shim to hand farmy to the control container (docker exec … farmy farmy …); it handed nothing.\n\n#{docker_situation}#{transcript}"
    wrong = execs.reject { |e| e["user"].to_s.split(":").first == uid.to_s }
    assert wrong.empty?, "Expected every docker exec of farmy in the control container to run as uid #{uid} (-u #{uid} or -u #{uid}:<any " \
                         "group>): the same user, whatever group the shell is in now; these ran otherwise:\n    " \
                         "#{wrong.map { |e| "#{shown_exec(e)}  as #{e["user"] || "root (no -u)"}" }.join("\n    ")}#{transcript}"
  end

  def assert_home_kept_in_a_volume
    control = docker_state["containers"]["farmy"] or flunk("Expected the control container to be up.\n\n#{docker_situation}#{transcript}")
    volumes = Array(control["volumes"]).reject { |v| v["name"].to_s.empty? }
    execs = farmy_execs
    refute_empty execs, "Expected the shim to hand farmy to the control container (docker exec … farmy farmy …); it handed nothing.\n\n#{docker_situation}#{transcript}"
    execs.each do |e|
      home = (e["env"] || {})["HOME"] || (control["env"] || {})["HOME"] || ([nil, "", "0", "0:0", "root"].include?(e["user"]) ? "/root" : "/")
      kept = volumes.find { |v| home == v["target"] || home.start_with?("#{v["target"].chomp("/")}/") }
      assert kept, "Expected the home farmy runs with in the control container to lie in a named volume mounted into it, so what farmy " \
                   "keeps there (Docker's client config and logins, git's config, known hosts) outlives the control container, as " \
                   "/root in its volume did before; #{shown_exec(e)} ran as #{e["user"] || "root"} with HOME=#{home}, and the control " \
                   "container's volumes are #{volumes.empty? ? "none" : volumes.map { |v| "#{v["name"]} at #{v["target"]}" }.join(", ")}.#{transcript}"
    end
  end

  # ── record 2026-10-29-1800 ──

  def the_shim_runs_under_sudo_e
    id = File.join(store_bin, "id")
    real = %w[/usr/bin/id /bin/id].find { |p| File.executable?(p) }
    File.write(id, "#!/bin/sh\ncase \"$*\" in -u|-ru|-g|-rg) echo 0 ;; *) exec #{real} \"$@\" ;; esac\n")
    File.chmod(0o755, id)
    (@fake_env ||= {}).merge!("SUDO_UID" => Process.uid.to_s, "SUDO_GID" => Process.gid.to_s, "SUDO_USER" => "dana", "SUDO_COMMAND" => "/usr/local/bin/farmy")
    note_situation "The shim runs under `sudo -E`: `id -u` and `id -g` say 0; SUDO_UID=#{Process.uid}, SUDO_GID=#{Process.gid} and " \
                   "SUDO_USER=dana name the user who ran sudo, and HOME is still theirs (#{home})."
  end

  def the_host_says_root_owns(*paths)
    full = paths.map { |p| machine_path(p).chomp("/") }
    real = %w[/usr/bin/stat /bin/stat].find { |p| File.executable?(p) }
    cases = full.map { |p| "#{Shellwords.escape(p)}|#{Shellwords.escape(p)}/*" }.join("|")
    File.write(File.join(store_bin, "stat"), <<~SH)
      #!/bin/sh
      # the host's stat, but root owns #{full.join(", ")} and what is in them
      fmt=; prev=; last=
      for a in "$@"; do
        case "$prev" in -c|--format|--printf) fmt=$a ;; esac
        case "$a" in --format=*|--printf=*) fmt=${a#*=} ;; esac
        prev=$a; last=$a
      done
      case "$last" in
        #{cases})
          if [ -n "$fmt" ] && [ -e "$last" ]; then printf '%s\n' "$fmt" | sed 's/%u/0/g; s/%g/0/g; s/%U/root/g; s/%G/root/g'; exit 0; fi ;;
      esac
      exec #{real} "$@"
    SH
    File.chmod(0o755, File.join(store_bin, "stat"))
    note_situation "The host says root owns #{paths.join(", ")} and what is in them: `stat` answers 0 (root) as their owner and group."
  end

  def control_container_made_for_root_by_a_root_caller
    write_file "farmy.yml", "format: 1\n" unless File.exist?(File.join(dir, "farmy.yml"))
    the_host_says_root_owns dir
    the_shim_sees_the_caller uid: 0, gid: 0, why: "root"
    shim "init"
    assert_success
    %w[id stat].each { |tool| FileUtils.rm_f(File.join(store_bin, tool)) }
    mark_control_container
    @farmy_execs_after_seq = @control_mark_seq # the setup's own init ran farmy as root; only the command's execs count
    note_situation "The control container was made by root's `farmy init` in this folder, which is a project folder (farmy.yml) the host " \
                   "said was root's: it was made to run farmy as root. From now on the caller is the invoking user (#{invoking_user}), and " \
                   "`stat` and `id` answer as they are."
  end

  def docker_client_warns
    change_docker_state { |s| s["cli_warning"] = "WARNING: Error loading config file: /home/dana/.docker/config.json: open /home/dana/.docker/config.json: permission denied" }
    note_situation "From now on the docker client prints on stderr, at every call, before its answer: `WARNING: Error loading config file: " \
                   "/home/dana/.docker/config.json: open …: permission denied`. Its answers on stdout and its exit codes are as without it."
  end

  def any_one_inspect_fails(nth)
    change_docker_state do |s|
      (s["inspect_fails_once"] ||= {})[LiveRuns::CONTROL] = nth
      (s["inspects_counted"] ||= {})[LiveRuns::CONTROL] = 0
    end
    note_situation "From now on the #{nth}#{{ 1 => "st", 2 => "nd", 3 => "rd" }.fetch(nth, "th")} docker inspect of the control container " \
                   "(docker inspect or docker container inspect) fails as a daemon that does not answer in time does: `Error response " \
                   "from daemon: context deadline exceeded`, exit 1. Every other one answers."
  end

  def assert_ran_as_the_invoking_user_or_refused_naming_the_error
    handed = control_execs_since_mark.select { |e| %w[farmy /usr/local/bin/farmy].include?(e["command"].first) }
    if handed.empty?
      assert finished.exit == 1 && stderr.include?("context deadline exceeded"),
             "Expected the command either to run as the user the control container was made for (-u #{invoking_user}), or, when the " \
             "shim could not read who that is, to be refused (exit 1) naming the daemon's error. Nothing was handed to the control " \
             "container, and it ended with exit #{finished.exit} without naming that error.\n\n#{docker_situation}#{transcript}"
    else
      wrong = handed.reject { |e| e["user"] == invoking_user }
      assert wrong.empty?, "Expected one failed inspect of the control container not to change who farmy runs as: it was made for the " \
                           "invoking user (-u #{invoking_user}). These ran otherwise:\n    " \
                           "#{wrong.map { |e| "#{shown_exec(e)}  as #{e["user"] || "root (no -u)"}" }.join("\n    ")}#{transcript}"
    end
  end

  def assert_handed_back(*folders)
    named = root_exec_lines.join("\n")
    folders.each do |folder|
      path = machine_path(folder)
      assert named.include?(path), "Expected the one-time hand-back (a command run as root in the control container when it is made) to " \
                                   "name #{folder} (#{path}), to give what is root's in it to the user farmy runs as; the commands run " \
                                   "as root there were:\n    #{root_exec_lines.empty? ? "none" : root_exec_lines.join("\n    ")}#{transcript}"
    end
  end

  def assert_hand_back_names_nothing_in(folder, but: nil)
    allowed = but && File.join(folder, but)
    named = root_exec_lines.flat_map { |line| line.scan(%r{#{Regexp.escape(folder)}(?:/[^\s'"]*)?}) }.uniq
    wrong = named.reject { |p| allowed && (p == allowed || p.start_with?("#{allowed}/")) }
    assert wrong.empty?, "Expected the one-time hand-back (commands run as root in the control container) to name nothing in #{folder}" \
                         "#{allowed ? " but what lies in #{allowed}, farmy's own state" : ", a folder the user farmy runs as does not own"}: " \
                         "the folder itself, farmy.yml, services/, .env and the rest are the user's, or another user's, to own. It named: " \
                         "#{wrong.join(", ")}\n    in: #{root_exec_lines.join("\n        ")}#{transcript}"
  end

  # ── with a real Docker ──

  def real_session_attached
    master, slave = PTY.open
    pid = Process.spawn(real_user_env, *as_the_plain_user, Target.path("farmy"), in: slave, out: slave, err: slave, chdir: dir, pgroup: true)
    slave.close
    tty = +""
    reader = Thread.new { loop { tty << master.readpartial(4096) } rescue nil }.tap { |t| t.report_on_exception = false }
    deadline = Time.now + Commands::COMMAND_TIMEOUT
    typed = false
    until tty.include?("No services yet") || Time.now > deadline
      if !typed && tty.include?("[y/N]")
        master.write("n\n")
        typed = true
      end
      flunk "A bare farmy through the real shim ended before its session showed:\n#{tty.scrub}" unless (Process.waitpid(pid, Process::WNOHANG).nil? rescue false)
      sleep 0.2
    end
    flunk "The session did not show its TUI (\"No services yet\") within #{Commands::COMMAND_TIMEOUT} s:\n#{tty.scrub}" unless tty.include?("No services yet")
    @terminal_output = tty
    yield
  ensure
    Process.kill("KILL", -pid) rescue nil if pid
    Process.wait(pid) rescue nil if pid
    reader&.kill
    master&.close rescue nil
  end

  def real_shim_as_the_user(*args)
    path = ([store_bin] + ENV.fetch("PATH").split(":").reject { |p| p == Farmy::FAKES }).join(":")
    prefix = as_the_plain_user
    executable, *rest = prefix.empty? ? [Target.path("farmy")] : prefix + [Target.path("farmy")]
    plumbing = machine_env
    saved = plumbing.keys.to_h { |key| [key, ENV[key]] }
    plumbing.each { |key, val| ENV[key] = val }
    execute executable, rest + args, shown_as: prefix.empty? ? "farmy" : "#{Shellwords.join(prefix)} farmy",
                                     env: store_env.merge("PATH" => path).merge(@host_gitconfig ? { "GIT_CONFIG_GLOBAL" => @host_gitconfig } : {})
  ensure
    saved&.each { |key, val| ENV[key] = val }
  end

  def real_shim_under_sudo_e(*args)
    skip "needs a root test runner (as the Mini's is) to run the real shim as root under sudo -E" unless Process.uid.zero?
    as_the_plain_user # the home and the test's folder are the plain user's, as a user's home is
    path = ([store_bin] + ENV.fetch("PATH").split(":").reject { |p| p == Farmy::FAKES }).join(":")
    plumbing = machine_env
    saved = plumbing.keys.to_h { |key| [key, ENV[key]] }
    plumbing.each { |key, val| ENV[key] = val }
    execute Target.path("farmy"), args, shown_as: "SUDO_UID=#{PLAIN_UID} SUDO_GID=#{PLAIN_UID} SUDO_USER=dana farmy",
            env: store_env.merge("PATH" => path, "SUDO_UID" => PLAIN_UID.to_s, "SUDO_GID" => PLAIN_UID.to_s, "SUDO_USER" => "dana",
                                 "SUDO_COMMAND" => Target.path("farmy")).merge(@host_gitconfig ? { "GIT_CONFIG_GLOBAL" => @host_gitconfig } : {})
  ensure
    saved&.each { |key, val| ENV[key] = val }
  end

  def default_home_left_root_s
    skip "needs a root test runner (as the Mini's is) to leave root's files in a user's home" unless Process.uid.zero?
    as_the_plain_user
    { "~/.config/farmy/farmy.yml" => "format: 1\n" }.each do |file, text|
      FileUtils.mkdir_p(File.dirname(machine_path(file)))
      File.write(machine_path(file), text)
    end
    FileUtils.mkdir_p(machine_path("~/.local/state/farmy/.work"))
    keep_root_s(*%w[~/.config/farmy ~/.config/farmy/farmy.yml ~/.local/state/farmy ~/.local/state/farmy/.work].map { |p| machine_path(p) })
    real_docker("rm", "-f", "farmy") rescue nil
    note_situation "~/.config/farmy (with farmy.yml) and ~/.local/state/farmy/.work were made by root, as 43583a9's `sudo -E farmy` left " \
                   "them; the home itself is the plain user's. No control container is up."
  end

  def shared_folder_of_root_s
    skip "needs a root test runner (as the Mini's is) to make a folder of root's" unless Process.uid.zero?
    shared = File.join(scratch, "shared")
    FileUtils.mkdir_p(File.join(shared, "services"))
    File.write(File.join(shared, "farmy.yml"), "format: 1\n")
    File.write(File.join(shared, ".env"), "GIT_USER_NAME=Dana Brooks\nGIT_USER_EMAIL=dana@example.com\n")
    File.chmod(0o777, shared)
    File.chmod(0o777, File.join(shared, "services"))
    keep_root_s(shared, File.join(shared, "services"), File.join(shared, "farmy.yml"), File.join(shared, ".env"))
    real_docker("rm", "-f", "farmy") rescue nil
    note_situation "#{shared} is a containers folder root owns, open to every user (0777), with root's farmy.yml, .env and services/. " \
                   "No control container is up."
    shared
  end

  def assert_root_s(*paths)
    paths.each do |path|
      st = File.lstat(machine_path(path))
      assert st.uid.zero? && st.gid.zero?, "Expected #{path} to stay root's (0:0): farmy hands over only its own folders, never a " \
                                           "folder another user owns or what is in it; it is #{st.uid}:#{st.gid}.#{transcript}"
    end
  end

  def assert_owned_by_the_user(*paths)
    uid, gid = plain_user
    paths.each do |path|
      full = machine_path(path)
      assert File.exist?(full), "Expected #{path} (#{full}) to exist.#{transcript}"
      st = File.lstat(full)
      assert st.uid == uid && st.gid == gid, "Expected #{path} to be the invoking user's (#{uid}:#{gid}) from the moment farmy wrote it; " \
                                             "it is #{st.uid}:#{st.gid}.#{transcript}"
    end
  end

  private

  # every farmy the shim handed to the control container; after a setup that ran farmy itself, only what came after it
  def farmy_execs = docker_state["execs"].select { |e| e["container"] == "farmy" && %w[farmy /usr/local/bin/farmy].include?(e["command"].first) && e["seq"].to_i > @farmy_execs_after_seq.to_i }

  # the commands run as root in the control container that are not farmy's own (the hand-back and the like), as lines
  def root_exec_lines
    docker_state["execs"].select { |e| e["container"] == "farmy" && [nil, "", "0", "0:0", "root", "root:root"].include?(e["user"]) && !%w[farmy /usr/local/bin/farmy].include?(e["command"].first) }
                         .map { |e| e["command"].join(" ") }
  end

  # root's files the test made stay root's when the plain user is given the test's folders
  def keep_root_s(*paths) = (@kept_root_s ||= []).concat(paths)

  def shown_exec(e) = "docker exec farmy #{Shellwords.join(e["command"])}"

  # a read-write bind mount whose source lies under a service's folder in the state folder's .work
  def writes_into_work?(line)
    line.scan(/(?:\A| )(?:-v|--volume|--mount)[ =](\S+)/).flatten.any? do |spec|
      if spec.include?("type=bind")
        source = spec[/(?:source|src)=([^,]+)/, 1].to_s
        source.match?(%r{/\.work/[^/]+/}) && !spec.match?(/(?:\A|,)(?:readonly|ro)(?:=true)?(?:,|\z)/)
      else
        source, _target, mode = spec.split(":")
        source.to_s.match?(%r{/\.work/[^/]+/}) && !mode.to_s.split(",").include?("ro")
      end
    end
  end

  def journal_lines
    calls = File.join(docker_journal, "calls.log")
    File.exist?(calls) ? File.readlines(calls, chomp: true) : []
  end

  # The plain user the real shim runs as: the test's own when that is not root; else uid and gid 4242, who gets the
  # test's folder and home, and the Docker socket's group so that it can reach the daemon, as a user in the docker group can.
  def plain_user = Process.uid.zero? ? [PLAIN_UID, PLAIN_UID] : [Process.uid, Process.gid]

  def as_the_plain_user
    return [] unless Process.uid.zero?
    FileUtils.chown_R(PLAIN_UID, PLAIN_UID, [scratch, dir])
    Array(@kept_root_s).each { |p| File.lchown(0, 0, p) if File.exist?(p) || File.symlink?(p) }
    socket = (ENV["DOCKER_HOST"].to_s.start_with?("unix://") ? ENV["DOCKER_HOST"].delete_prefix("unix://") : "/var/run/docker.sock")
    ["setpriv", "--reuid=#{PLAIN_UID}", "--regid=#{PLAIN_UID}", "--groups=#{File.stat(socket).gid}", "--"]
  end

  def real_user_env
    path = ([store_bin] + ENV.fetch("PATH").split(":").reject { |p| p == Farmy::FAKES }).join(":")
    env = Workspace::GIT_ENV.merge(machine_env).merge(store_env).merge("PATH" => path, "TERM" => "xterm-256color")
    env["GIT_CONFIG_GLOBAL"] = @host_gitconfig if @host_gitconfig
    env.transform_values { |v| v&.to_s }
  end
end
