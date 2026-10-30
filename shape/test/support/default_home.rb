# A user's machine, and where farmy keeps things on it (record 2026-10-29-0926).
#
# Every farmy call the kit makes (farmy, shim, real_shim, the fake docker asked directly) runs with HOME set to a
# folder of the test's own, XDG_CONFIG_HOME and XDG_STATE_HOME unset, and FARMY_DIR naming the test's folder: the
# test's folder is the containers folder, and nothing can reach the real ~/.config. A test that plays a user's
# machine says so first, and farmy then finds its folder by itself:
#
#   on_a_fresh_machine                                farmy is told nothing about its folder (no FARMY_DIR)
#   machine_path "~/.config/farmy"                    a path on that machine; ~ is the test's home
#   home_holds "~/.config/farmy/farmy.yml" => "…"     files put on the machine before the command
#   assert_machine_file "~/.config/farmy/services/shop.yml", includes: "repo: …"
#   assert_machine_folder "~/.local/state/farmy/.work"   · refute_machine_path "~/.config/farmy/.work"
#   above_holds "farmy.yml" · the_folder_above        the folder above the test's (after folder_named)
#   config_home_is_the_folder_above                   XDG_CONFIG_HOME names it: the test's folder is the default home
#   assert_status_folder "~/.config/farmy (state in ~/.local/state/farmy)"   the folder line of farmy status
#   farmy_on_a_terminal "add", …, typing: "y"         stdin is a terminal; the answer is typed when farmy asks [y/N]
#   assert_asked "Keep ~/.config/farmy in git? [y/N]" · refute_asked "in git?"
#   assert_git_ignores "~/.config/farmy", ".env"      · refute_git_ignores …   asked of git, in a copy
#   assert_repository "~/.config/farmy", holding: [...]   · refute_repository "~/.config/farmy"
#   home_is_a_repository "~/.config"                  a Git repository there, as a dotfiles one would be
#   macos_host                                        the shim's uname says Darwin
#   assert_mounted_at_own_path "farmy", "~/.config/farmy"   the control container bind-mounts it at its host path
#   assert_handed_to_farmy "status", "FARMY_DIR" => path    the docker exec of that farmy command carried these
#   refute_handed_to_farmy "status", "FARMY_HOST_GIT_TOP"   … and carried none of these (record 2026-10-29-1105)
#   home_is_unset                                     HOME is not set, as for a program a service manager starts
#   mac_developer_tools installed: false              xcode-select -p fails (with macos_host): /usr/bin/git is a stub
#   record_git_runs · refute_git_run                  every git the shim runs is written down · it ran none
require "fileutils"
require "open3"
require "pty"
require "tmpdir"

module DefaultHome
  REAL_DOCKER_CONFIG = ENV["DOCKER_CONFIG"] || File.join(Dir.home, ".docker")

  # What every farmy call gets on top of the fake docker's plumbing.
  def machine_env
    { "HOME" => home, "XDG_CONFIG_HOME" => nil, "XDG_STATE_HOME" => nil, "FARMY_HOST_HOME" => nil,
      "DOCKER_CONFIG" => REAL_DOCKER_CONFIG, "FARMY_DIR" => (@farmy_finds_its_folder ? nil : dir),
      # a runner started with sudo passes these on; farmy acts for that user under sudo (record 2026-10-29-1800)
      "SUDO_UID" => nil, "SUDO_GID" => nil, "SUDO_USER" => nil, "SUDO_COMMAND" => nil }
  end

  def on_a_fresh_machine
    @farmy_finds_its_folder = true
    note_situation "A machine of the test's own: HOME is #{home}. XDG_CONFIG_HOME, XDG_STATE_HOME and FARMY_DIR " \
                   "are not set unless the command line shows them, so farmy finds its folder by itself."
  end

  def home = File.join(scratch, "home").tap { |d| FileUtils.mkdir_p(d) }

  def machine_path(path) = path.start_with?("~/") ? File.join(home, path.delete_prefix("~/")) : path

  def home_holds(files)
    files.each do |path, content|
      FileUtils.mkdir_p(File.dirname(machine_path(path)))
      File.write(machine_path(path), content)
    end
    note_situation "On the machine: #{files.keys.join(", ")}."
  end

  def home_folders(*paths)
    paths.each { |p| FileUtils.mkdir_p(machine_path(p)) }
    note_situation "On the machine, these folders exist (empty): #{paths.join(", ")}."
  end

  def home_loses(path)
    FileUtils.rm_rf(machine_path(path))
    note_situation "#{path} was removed from the machine."
  end

  # The workshop fixture (.env with a Git identity; shop, notes and toolkit defined; no farmy.yml) copied there.
  def workshop_in(path)
    FileUtils.mkdir_p(machine_path(path))
    FileUtils.cp_r(File.join(TEST_ROOT, "fixtures", "workspaces", "workshop", "."), machine_path(path))
    note_situation "#{path} holds the workshop: .env with a Git identity, services/shop.yml, notes.yml, toolkit.yml, and no farmy.yml."
  end

  # A folder in the test's own folder (assert_file is for files).
  def assert_folder(path)
    assert File.directory?(File.join(dir, path)), "Expected a folder at #{path} in #{dir}.\n\n#{listing}#{transcript}"
  end

  # stdout is that path, absolute, and nothing else.
  def assert_prints_only(path)
    assert stdout == "#{machine_path(path)}\n", "Expected stdout to be exactly the line #{machine_path(path)}.#{transcript}"
  end

  # farmy status --json: "folder": {"path": …, "state": …}, both absolute.
  def assert_json_folder(path:, state:)
    folder = status_json["folder"]
    assert folder.is_a?(Hash), "Expected farmy status --json to have a top-level \"folder\": {\"path\": …, \"state\": …}; it has #{folder.inspect}.#{transcript}"
    { "path" => path, "state" => state }.each do |key, want|
      assert folder[key] == machine_path(want), "Expected \"folder\".\"#{key}\" to be #{machine_path(want).inspect} (#{want}, absolute); it is #{folder[key].inspect}.#{transcript}"
    end
  end

  # ── the README at the repository root ──

  # A code block of exactly three command lines: the one-line installer, farmy add …, and farmy.
  def assert_readme_quick_start_is_three_lines
    blocks = root_file("README.md").scan(/^```[a-z]*\n(.*?)^```/m).flatten
    commands = blocks.map { |b| b.lines.map { |l| l.sub(/\s+#.*$/, "").strip }.reject { |l| l.empty? || l.start_with?("#") } }
    three = commands.find { |c| c.size == 3 && c[0].start_with?("curl -fsSL ") && c[0].end_with?("| sh") && c[1].start_with?("farmy add ") && c[2] == "farmy" }
    shown = commands.select { |c| c.any? { |l| l.start_with?("farmy add") } }.map { |c| c.join(" / ") }
    assert three, "Expected the README (repository root) to have a code block of exactly three commands, comments aside: `curl -fsSL …/install | sh`, `farmy add <url> --image <image>` and `farmy`. The blocks with farmy add read: #{shown.empty? ? "none" : shown.join("  |  ")}."
  end

  # No command line in the README's code blocks matches.
  def refute_readme_code(pattern, what)
    blocks = root_file("README.md").scan(/^```[a-z]*\n(.*?)^```/m).flatten
    hits = blocks.flat_map(&:lines).map(&:strip).select { |l| pattern === l }
    assert hits.empty?, "Expected no command in the README's code blocks to #{what}; these do: #{hits.join("  |  ")}."
  end

  def assert_readme_section_says(heading, *phrases)
    text = root_file("README.md")
    section = text[/^##+ #{Regexp.escape(heading)}\s*\n(.*?)(?=^## |\z)/m, 1]
    assert section, "Expected the README (repository root) to have a section headed \"#{heading}\"; its headings are: #{text.scan(/^##+ (.+)$/).flatten.join(", ")}."
    missing = phrases.reject { |p| section.include?(p) }
    assert missing.empty?, "Expected the README's section \"#{heading}\" to mention each of #{phrases.map(&:inspect).join(", ")}; it does not mention: #{missing.map(&:inspect).join(", ")}."
  end

  def assert_machine_file(path, includes: nil)
    file = machine_path(path)
    assert File.file?(file), "Expected a file at #{path} (#{file}).\n\n#{home_listing}#{transcript}"
    return unless includes
    assert File.read(file).include?(includes), "Expected #{path} to include #{includes.inspect}.\n\n  #{path}:\n#{File.read(file).gsub(/^/, "    ")}#{transcript}"
  end

  def assert_machine_folder(path)
    assert File.directory?(machine_path(path)), "Expected a folder at #{path} (#{machine_path(path)}).\n\n#{home_listing}#{transcript}"
  end

  def refute_machine_path(path)
    refute File.exist?(machine_path(path)), "Expected nothing at #{path} (#{machine_path(path)}).\n\n#{home_listing}#{transcript}"
  end

  # ── other folders ──

  def the_folder_above = File.dirname(dir)

  def above_holds(name, content = "")
    raise ArgumentError, "above_holds needs folder_named first, so that the folder above is the test's own" unless @parent
    File.write(File.join(the_folder_above, name), content)
    note_situation "The folder above the one the command runs in, #{the_folder_above}, holds #{name}."
  end

  def config_home_is_the_folder_above
    raise ArgumentError, "config_home_is_the_folder_above needs folder_named \"farmy\" first" unless @parent && File.basename(dir) == "farmy"
    (@fake_env ||= {})["XDG_CONFIG_HOME"] = the_folder_above
    note_situation "XDG_CONFIG_HOME is #{the_folder_above}, so the folder the command runs in, #{dir}, is the default home's config folder."
  end

  # The line of farmy status that names the folder: `folder       <rest>`.
  def assert_status_folder(rest)
    line = stdout.lines.map(&:chomp).find { |l| l.start_with?("folder ") }
    assert line, "Expected farmy status to print a line `folder       <the folder in use>` (its first line, in the column of `ports`); it prints none.#{transcript}"
    assert line.sub(/\Afolder\s+/, "").rstrip == rest, "Expected the folder line to read `folder       #{rest}`; it reads `#{line}`.#{transcript}"
  end

  # ── a terminal ──

  # farmy with its stdin on a pseudo-terminal (stdout and stderr stay pipes, as through the shim). What `typing:`
  # says is typed, followed by Enter, once farmy shows `[y/N]`; a command that asks nothing never reads it.
  def farmy_on_a_terminal(*args, typing:, env: {})
    plumbing = farmy_env
    saved = plumbing.keys.to_h { |key| [key, ENV[key]] }
    plumbing.each { |key, val| ENV[key] = val }
    env = { "GIT_CONFIG_GLOBAL" => @host_gitconfig }.merge(env) if @host_gitconfig
    run_on_a_terminal(Target.path(PROGRAM), args.map(&:to_s), typing, env)
  ensure
    saved&.each { |key, val| ENV[key] = val }
  end

  def assert_asked(question)
    asked = (stdout + stderr + @terminal_output.to_s).include?(question)
    assert asked, "Expected farmy to ask #{question.inspect} (on stdout or stderr), and it did not.#{transcript}"
  end

  def refute_asked(text)
    asked = (stdout + stderr + @terminal_output.to_s).include?(text)
    refute asked, "Expected farmy to ask nothing about #{text.inspect}, and it did.#{transcript}"
  end

  # ── git ──

  def assert_git_ignores(folder, *paths)
    paths.each { |p| assert git_ignores?(folder, p), "Expected the .gitignore farmy wrote in #{folder} to keep #{p} out of git; git does not ignore it.\n\n#{gitignore_shown(folder)}#{transcript}" }
  end

  def refute_git_ignores(folder, *paths)
    paths.each { |p| refute git_ignores?(folder, p), "Expected #{p} in #{folder} to be kept in git; the .gitignore farmy wrote ignores it.\n\n#{gitignore_shown(folder)}#{transcript}" }
  end

  def assert_repository(folder, holding:)
    root = machine_path(folder)
    assert File.directory?(File.join(root, ".git")), "Expected #{folder} to be a Git repository of its own (#{root}/.git); it is not.\n\n#{home_listing}#{transcript}"
    count, ok = Open3.capture2e(Workspace::GIT_ENV, "git", "-C", root, "-c", "safe.directory=*", "rev-list", "--count", "HEAD")
    assert ok.success? && count.strip == "1", "Expected the repository #{folder} to have exactly one commit; git says: #{count.strip}.#{transcript}"
    files, = Open3.capture2e(Workspace::GIT_ENV, "git", "-C", root, "-c", "safe.directory=*", "ls-tree", "-r", "--name-only", "HEAD")
    assert files.split("\n").sort == holding.sort, "Expected the first commit of #{folder} to hold exactly #{holding.sort.join(", ")}; it holds #{files.split("\n").sort.join(", ")}.#{transcript}"
  end

  def refute_repository(folder)
    refute File.exist?(File.join(machine_path(folder), ".git")), "Expected #{folder} not to be made a Git repository; it has a .git.#{transcript}"
  end

  def home_is_a_repository(folder)
    FileUtils.mkdir_p(machine_path(folder))
    out, status = Open3.capture2e(Workspace::GIT_ENV, "git", "init", "--quiet", "--initial-branch=main", machine_path(folder))
    raise "git init failed while preparing the machine:\n#{out}" unless status.success?
    note_situation "#{folder} is a Git repository (#{machine_path(folder)}), as a dotfiles repository would be."
  end

  # ── the shim ──

  def macos_host
    uname = File.join(store_bin, "uname")
    real = %w[/bin/uname /usr/bin/uname].find { |p| File.executable?(p) }
    File.write(uname, "#!/bin/sh\ncase \"$*\" in ''|-s) echo Darwin ;; *) exec #{real} \"$@\" ;; esac\n")
    File.chmod(0o755, uname)
    note_situation "The host is a Mac: uname says Darwin."
  end

  def assert_mounted_at_own_path(name, folder)
    path = machine_path(folder)
    assert File.directory?(path), "Expected #{folder} (#{path}) to exist on the host before the control container mounts it; it does not.\n\n#{home_listing}#{transcript}"
    assert_binds name, path, at: path
  end

  # The docker exec of `farmy <words…>` in the control container carried these variables in its environment.
  def assert_handed_to_farmy(words, variables)
    words = Array(words)
    execs = docker_state["execs"].select { |e| e["container"] == "farmy" && e["command"].first == "farmy" }
    hit = execs.reverse.find { |e| e["command"][1, words.size] == words }
    assert hit, "Expected the shim to run `farmy #{words.join(" ")}` in the control container with docker exec; it ran: #{execs.map { |e| e["command"].join(" ") }.uniq.join("; ").then { |s| s.empty? ? "nothing" : s }}.\n\n#{docker_situation}#{transcript}"
    env = hit["env"] || {}
    variables.each do |key, value|
      value = machine_path(value)
      assert env[key] == value, "Expected the docker exec of `farmy #{words.join(" ")}` to carry #{key}=#{value} (-e on the exec); it carries #{env.key?(key) ? "#{key}=#{env[key]}" : "no #{key}"}. Its environment: #{env.empty? ? "nothing" : env.map { |k, v| "#{k}=#{v}" }.join(" ")}.#{transcript}"
    end
  end

  # The docker exec of `farmy <words…>` ran in that folder (-w).
  def assert_farmy_ran_in(words, folder)
    words = Array(words)
    execs = docker_state["execs"].select { |e| e["container"] == "farmy" && e["command"].first == "farmy" }
    hit = execs.reverse.find { |e| e["command"][1, words.size] == words }
    assert hit, "Expected the shim to run `farmy #{words.join(" ")}` in the control container; it ran: #{execs.map { |e| e["command"].join(" ") }.uniq.join("; ").then { |s| s.empty? ? "nothing" : s }}.\n\n#{docker_situation}#{transcript}"
    assert hit["workdir"] == machine_path(folder), "Expected `farmy #{words.join(" ")}` to run in #{machine_path(folder)} (docker exec -w); it ran in #{hit["workdir"].inspect}.#{transcript}"
  end

  # The docker exec of `farmy <words…>` carried none of these variables (or only an empty one).
  def refute_handed_to_farmy(words, *keys)
    words = Array(words)
    execs = docker_state["execs"].select { |e| e["container"] == "farmy" && e["command"].first == "farmy" }
    hit = execs.reverse.find { |e| e["command"][1, words.size] == words }
    assert hit, "Expected the shim to run `farmy #{words.join(" ")}` in the control container with docker exec; it ran: #{execs.map { |e| e["command"].join(" ") }.uniq.join("; ").then { |s| s.empty? ? "nothing" : s }}.\n\n#{docker_situation}#{transcript}"
    env = hit["env"] || {}
    keys.each do |key|
      assert env[key].to_s.empty?, "Expected the docker exec of `farmy #{words.join(" ")}` to carry no #{key}; it carries #{key}=#{env[key]}.#{transcript}"
    end
  end

  # HOME is not set, as for a program a service manager starts (XDG_CONFIG_HOME and XDG_STATE_HOME neither).
  def home_is_unset
    (@fake_env ||= {})["HOME"] = nil
    note_situation "HOME is not set, as for a program a service manager starts; XDG_CONFIG_HOME and XDG_STATE_HOME are not set either."
  end

  # The Mac's xcode-select -p answers as it does with or without the developer tools.
  def mac_developer_tools(installed:)
    answer = installed ? "echo /Library/Developer/CommandLineTools" : "echo 'xcode-select: error: unable to get active developer directory' >&2; exit 2"
    path = File.join(store_bin, "xcode-select")
    File.write(path, "#!/bin/sh\n[ \"$1\" = -p ] || exit 1\n#{answer}\n")
    File.chmod(0o755, path)
    note_situation(installed ? "The Mac has the developer tools: xcode-select -p names them." :
      "The Mac has no developer tools: xcode-select -p fails, and /usr/bin/git there is Apple's stub, which offers to install them each time it runs.")
  end

  # Every git the shim runs on the host is written down; refute_git_run reads that.
  def record_git_runs
    real = %w[/usr/bin/git /usr/local/bin/git].find { |p| File.executable?(p) }
    path = File.join(store_bin, "git")
    File.write(path, "#!/bin/sh\nprintf '%s\\n' \"git $*\" >> '#{git_runs_log}'\nexec #{real} \"$@\"\n")
    File.chmod(0o755, path)
  end

  def refute_git_run
    runs = File.exist?(git_runs_log) ? File.readlines(git_runs_log, chomp: true) : []
    assert runs.empty?, "Expected the shim to run no git on this Mac without the developer tools (/usr/bin/git there is a stub that offers to install them, a dialog on every farmy command); it ran:\n    #{runs.join("\n    ")}#{transcript}"
  end

  private

  def git_runs_log = File.join(scratch, "git-runs")

  def home_listing
    files = Dir.glob("**/*", File::FNM_DOTMATCH, base: home).reject { |p| p.end_with?("/.") || p == "." || p.include?("/.git/") }.sort
    files.empty? ? "  The machine's home (#{home}) is empty." : "  On the machine's home (#{home}):\n#{files.first(60).map { |f| "    ~/#{f}#{"/" if File.directory?(File.join(home, f))}" }.join("\n")}"
  end

  def git_ignores?(folder, path)
    ignore = File.join(machine_path(folder), ".gitignore")
    flunk "Expected a .gitignore in #{folder} (#{ignore}); there is none.\n\n#{home_listing}#{transcript}" unless File.file?(ignore)
    Dir.mktmpdir("gitignore-") do |copy|
      Open3.capture2e(Workspace::GIT_ENV, "git", "init", "--quiet", copy)
      FileUtils.cp(ignore, File.join(copy, ".gitignore"))
      _, status = Open3.capture2e(Workspace::GIT_ENV, "git", "-C", copy, "check-ignore", "--quiet", "--no-index", path)
      status.exitstatus == 0
    end
  end

  def gitignore_shown(folder)
    ignore = File.join(machine_path(folder), ".gitignore")
    File.file?(ignore) ? "  #{folder}/.gitignore:\n#{File.read(ignore).gsub(/^/, "    ")}" : "  #{folder} has no .gitignore."
  end

  def run_on_a_terminal(executable, args, typing, env)
    line = "#{File.basename(PROGRAM)} #{args.join(" ")}    (stdin is a terminal; typed at [y/N]: #{typing.inspect})"
    remember_workspace
    before = [*situation, *repository_state]
    master, slave = PTY.open
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    pid = Process.spawn(Workspace::GIT_ENV.merge(env.transform_values(&:to_s)), executable, *args,
                        in: slave, out: out_w, err: err_w, chdir: dir, pgroup: true)
    [slave, out_w, err_w].each(&:close)
    out, err, tty = +"", +"", +""
    readers = [[out_r, out], [err_r, err], [master, tty]].map do |io, buffer|
      Thread.new { loop { buffer << io.readpartial(4096) } rescue nil }.tap { |t| t.report_on_exception = false }
    end
    waiter = Process.detach(pid)
    typed = false
    deadline = Time.now + Commands::COMMAND_TIMEOUT
    while waiter.alive? && Time.now < deadline
      if !typed && (out + err + tty).include?("[y/N]")
        master.write("#{typing}\n")
        typed = true
      end
      sleep 0.02
    end
    if waiter.alive?
      Process.kill("KILL", -pid) rescue nil
      waiter.join
      raise Minitest::Assertion, "The command was still running after #{Commands::COMMAND_TIMEOUT} s and was stopped.\n\n  $ #{line}\n  stdout: #{out}\n  stderr: #{err}"
    end
    status = waiter.value
    readers.first(2).each { |t| t.join(5) }
    master.close
    @terminal_output = tty
    @finished = Commands::Finished.new(line, out.scrub, err.scrub, status.exitstatus || "none (killed by signal #{status.termsig})", before)
  end
end
