# The mesh egress node (farmy.yml egress:): what the fake docker plays of it, and what a test can see.
#
#   mesh_registered name: "mini.tail1234.ts.net", address: "100.101.102.103"   the node's state on the farmy-egress volume
#   container_log "farmy-egress", "To authenticate, visit: …", on: :stderr, after: 3   what docker logs prints, from which read on
#   assert_ran_in_times "farmy-egress", "--auth-key", 1 · assert_stdout_order "== egress", "== secrets"
#   assert_given_on_stdin "farmy-egress", "tskey-auth-…"                      a command run in it received this on stdin
#   assert_told "farmy-egress", "--login-server=https://…"                    in its environment, its command or a command run in it
#   assert_provider_saw_running "farmy-egress"                                the container was running when the provider ran
#   assert_toolbox_installs "shop", "netcat-openbsd"                          the install script in the dev image's build context names it
#   assert_stdout_once "text" · assert_url_printed_once "https://…"          exactly once in stdout; alone on one line
#   egress_json                                                               the egress entry of farmy status --json
#   assert_login_command "farmy-egress", "--login-server=https://…"           the node's tailscale up carries it, no empty argument
#   docker_refuses_device "/dev/net/tun" · assert_device · refute_device · assert_capability "farmy-egress", "NET_ADMIN"
#   clone_fails "shop", "fatal: …"                                            the new container's entrypoint reports a failed clone
#   assert_compose_files_resolved                                             no $NAME for compose to fill under .work/
module Egress
  def mesh_registered(name:, address:)
    change_docker_state { |s| (s["volumes"]["farmy-egress"] ||= {})["mesh"] = { "name" => name, "address" => address } }
    note_situation "The volume farmy-egress holds a registered node: #{name} #{address}."
  end

  # What docker logs <name> prints, on stderr as tailscaled logs (on: :stdout otherwise); after: n means the
  # first n reads print nothing, as a line that is logged later.
  def container_log(name, text, on: :stderr, after: 0)
    change_docker_state { |s| (s["logs"] ||= {})[name] = { "text" => text, "stream" => on.to_s, "after" => after, "reads" => 0 } }
    note_situation "docker logs #{name} prints on #{on}#{" from its #{after + 1}. read on" if after > 0}: #{text.strip.inspect}."
  end

  def assert_ran_in_times(name, text, times)
    hits = docker_state["execs"].select { |e| e["container"] == name && ran_text?(e, text) }
    assert hits.size == times, "Expected a command matching #{text.inspect} to have been run in #{name} #{times} time#{"s" unless times == 1}; it was run #{hits.size} time#{"s" unless hits.size == 1}.\n\n#{docker_situation}#{transcript}"
  end

  # These texts appear in stdout in this order, each on a line of its own start.
  def assert_stdout_order(*texts)
    lines = stdout.lines
    positions = texts.map { |t| lines.index { |l| t.is_a?(Regexp) ? l.match?(t) : l.start_with?(t) } }
    missing = texts.zip(positions).select { |_, p| p.nil? }.map(&:first)
    assert missing.empty?, "Expected stdout to have lines starting with #{texts.map(&:inspect).join(", ")}; missing: #{missing.map(&:inspect).join(", ")}.#{transcript}"
    assert positions == positions.sort, "Expected these lines in stdout in this order: #{texts.map(&:inspect).join(", ")}; they come as #{positions.each_with_index.sort_by(&:first).map { |_, i| texts[i].inspect }.join(", ")}.#{transcript}"
  end
  # The daemon refuses this device, as Docker does where the host has none (compose up fails).
  def docker_refuses_device(path)
    change_docker_state { |s| (s["refused_devices"] ||= []) << path }
    note_situation "The Docker daemon refuses the device #{path}."
  end

  def assert_device(name, path)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    assert Array(c["devices"]).include?(path), "Expected #{name} to have the device #{path}; it has #{Array(c["devices"]).empty? ? "none" : c["devices"].join(", ")}.\n\n#{docker_situation}#{transcript}"
  end

  def refute_device(name, path)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    assert !Array(c["devices"]).include?(path), "Expected #{name} to run without the device #{path}; it has it.\n\n#{docker_situation}#{transcript}"
  end

  def assert_capability(name, cap)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    assert Array(c["cap_add"]).include?(cap), "Expected #{name} to have the capability #{cap} (cap_add); it has #{Array(c["cap_add"]).empty? ? "none added" : c["cap_add"].join(", ")}.\n\n#{docker_situation}#{transcript}"
  end

  # The new container's entrypoint will report this clone as failed, with git's reason.
  def clone_fails(name, reason)
    change_docker_state { |s| (s["clone_results"] ||= {})[name] = "failed\n#{reason}\n" }
    note_situation "The clone in #{name} fails: #{reason}"
  end

  def assert_given_on_stdin(name, text)
    given = docker_state["execs"].select { |e| e["container"] == name && e["stdin"] }
    assert given.any? { |e| e["stdin"].include?(text) }, "Expected a command run in #{name} (docker exec -i) to have received #{text.inspect} on stdin; #{given.empty? ? "no command run in it received anything on stdin" : "what was received does not hold it"}.\n\n#{docker_situation}#{transcript}"
  end

  def refute_given_on_stdin(name, text)
    given = docker_state["execs"].select { |e| e["container"] == name && e["stdin"].to_s.include?(text) }
    assert given.empty?, "Expected no command run in #{name} to have received #{text.inspect} on stdin; #{given.map { |e| e["command"].join(" ") }.join(", ")} did.\n\n#{docker_situation}#{transcript}"
  end

  # A command matching text was run in the container with this variable in its environment (docker exec -e).
  def assert_exec_env(name, text, key, value)
    hits = docker_state["execs"].select { |e| e["container"] == name && ran_text?(e, text) }
    assert !hits.empty?, "Expected a command matching #{text.inspect} to have been run in #{name}.\n\n#{docker_situation}#{transcript}"
    assert hits.any? { |e| (e["env"] || {})[key] == value }, "Expected #{text.inspect} to run in #{name} with #{key}=#{value} in its environment (docker exec -e); it had: #{hits.map { |e| (e["env"] || {}).map { |k, v| "#{k}=#{v}" }.join(" ") }.join(" | ").then { |s| s.empty? ? "nothing" : s }}.\n\n#{docker_situation}#{transcript}"
  end

  # What a terminal shows of stdout and stderr: per line the part after the last carriage return, escapes taken off.
  def screen_lines
    (stdout + stderr).split("\n").map { |l| l.split("\r").last.to_s.gsub(/\e\[[0-9;]*[A-Za-z]/, "") }.reject { |l| l.strip.empty? }
  end

  def refute_on_screen(text)
    shown = screen_lines.select { |l| l.include?(text) }
    assert shown.empty?, "Expected #{text.inspect} not to stay on the screen (a line overwritten in place is fine); it stays on: #{shown.join(" | ")}.#{transcript}"
  end

  def assert_told(name, text)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    places = c["env"].values.map(&:to_s) + [Array(c["process"]).join(" "), Array(c["command"]).join(" ")] + docker_state["execs"].select { |e| e["container"] == name }.map { |e| e["command"].join(" ") }
    assert places.any? { |p| p.include?(text) }, "Expected #{name} to have been told #{text.inspect}: in its environment, its command line or a command run in it; it was not.\n\n#{docker_situation}#{transcript}"
  end

  def assert_provider_saw_running(name)
    line = read_file("provider.log").lines.grep(/^running:/).first.to_s
    assert line.split.include?(name), "Expected #{name} to be running when the provider was run; the provider saw running: #{line.delete_prefix("running:").strip.then { |l| l.empty? ? "nothing" : l }}.#{transcript}"
  rescue Errno::ENOENT
    flunk "Expected the provider to have been run (provider.log), and it was not.#{transcript}"
  end

  def assert_toolbox_installs(service, text)
    tag = "farmy/#{service}:dev"
    build = docker_state["images"][tag] or flunk("Expected the app image #{tag} to have been built.\n\n#{builds_situation}#{transcript}")
    script = (build["file_texts"] || {})["install.sh"].to_s
    assert script.include?(text), "Expected the toolbox's install.sh in the build context of #{tag} to install #{text}; it does not name it.#{transcript}"
  end

  def assert_stdout_once(text)
    n = stdout.scan(text).size
    assert n == 1, "Expected #{text.inspect} exactly once in stdout; it is there #{n} times.#{transcript}"
  end

  # The URL stands alone on a line of stdout exactly once (the instruction block); the live waiting line carries it too.
  def assert_url_printed_once(url)
    n = stdout.lines.count { |l| l.strip == url }
    assert n == 1, "Expected the URL #{url} alone on a line of stdout exactly once (the instruction to register); it is alone on #{n} lines.#{transcript}"
  end

  # The node's login command (a `tailscale up` or `tailscale login` in the container's own command or in
  # a command farmy ran there), with $NAME expanded from the container's environment as its shell would:
  # it carries this argument as a word of its own, and no login argument is empty (`--login-server=`).
  def assert_login_command(name, argument)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    texts = [Array(c["command"]).join(" ")] + docker_state["execs"].select { |e| e["container"] == name }.map { |e| e["command"].join(" ") }
    logins = texts.flat_map { |t| t.scan(/tailscale (?:up|login)\b[^;&|\n]*/) }
    assert !logins.empty?, "Expected a tailscale up or tailscale login in #{name}: in its command or a command run in it; there is none.\n\n#{docker_situation}#{transcript}"
    env = c["env"] || {}
    expanded = logins.map { |l| l.gsub(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/) { env[$1].to_s }.split }
    empty = expanded.flatten.select { |w| w.end_with?("=") }
    assert empty.empty?, "Expected no empty login argument in #{name}; there is #{empty.uniq.join(", ")} in: #{logins.join(" / ")}.\n\n#{docker_situation}#{transcript}"
    assert expanded.any? { |words| words.include?(argument) }, "Expected the login command in #{name} to carry #{argument}; it reads: #{expanded.map { |w| w.join(" ") }.join(" / ")}.\n\n#{docker_situation}#{transcript}"
  end

  # No compose file farmy wrote under .work/ holds a variable for compose to fill ($NAME or ${NAME};
  # $$ is a literal $), and compose warned about none.
  def assert_compose_files_resolved
    files = Dir.glob(File.join(dir, ".work", "**", "*.{yml,yaml}"))
    assert !files.empty?, "Expected compose files under .work/; there are none.#{transcript}"
    found = files.flat_map do |f|
      File.read(f).gsub("$$", "").scan(/\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/).uniq.map { |v| "#{v} in #{f.delete_prefix("#{dir}/")}" }
    end
    assert found.empty?, "Expected no variable left for compose to fill in the compose files farmy writes (a value goes into the file, a $ for a shell in the container is written $$); found: #{found.join(", ")}.#{transcript}"
    refute_stderr "variable is not set"
  end

  def egress_json
    status_json.fetch("egress") { flunk "Expected status --json to have an egress entry (null without egress: in farmy.yml).#{transcript}" }
  end
end
