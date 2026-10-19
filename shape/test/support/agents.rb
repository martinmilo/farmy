# Agents as data: the shipped catalogue (agents.yml in the work folder), entries of your own under
# agents: in farmy.yml, and what the toolbox build and the entrypoint are given about each agent.
#
#   assert_agent_built "shop", "mytool", install: "npm install -g mytool@2.4.0", login: ".mytool"
#                                       the agents.tsv in the build context of farmy/shop:dev gives the agent these columns
#   assert_agent_built "shop", "cursor", install_apt: /cursor.com\/install/, install_apk: ""   an install line per base
#   agent_json "shop", "claude"              one agent's entry in the service's agents map of farmy status --json
#   assert_catalogue_entries "claude", "codex", …
#                                       agents.yml holds exactly these, known fields only, a documentation URL in a comment above each
#   assert_catalogue_installs_outside_homes   no catalogue install line runs as dev or names a home directory
#   assert_catalogue_installs_download_then_run   no catalogue install line pipes curl/wget into a shell
#   assert_guide_installs_keep_the_catalogue_rules "docs/factory.md"   agent install lines in the guide's yaml blocks keep both rules
#   assert_toolbox_version_check_limited_to_30_s "shop"   the toolbox build runs something under timeout 30
#   assert_toolbox_runs_a_step_as_dev "shop"   the toolbox build of farmy/shop:dev runs something as dev (USER dev, or su/runuser/gosu/setpriv dev)
require "yaml"
require "open3"

module Agents
  FIELDS = %w[install login state headless_login headless token_env env api api_hosts mcp_add status_hooks process mode version factory_login].freeze
  COLUMNS = %w[name install_apt install_apk login state mcp_add hooks_file hooks_events process version].freeze

  def assert_agent_built(service, agent, **fields)
    tag = "farmy/#{service}:dev"
    build = docker_state["images"][tag]
    assert build, "Expected the app image #{tag} to have been built.\n\n#{builds_situation}#{transcript}"
    text = (build["file_texts"] || {})["agents.tsv"]
    assert text, "Expected agents.tsv in the build context of #{tag}, one line per agent, the columns #{COLUMNS.join(", ")} separated by tabs (an empty column for null); the context holds: #{build["files"].empty? ? "nothing" : build["files"].join(", ")}.#{transcript}"
    rows = text.lines(chomp: true).reject(&:empty?).map { |l| COLUMNS.zip(l.split("\t", -1)).to_h }
    row = rows.find { |r| r["name"] == agent }
    assert row, "Expected a line for #{agent} in agents.tsv of #{tag}; it has lines for: #{rows.map { |r| r["name"] }.join(", ")}.#{transcript}"
    fields = fields.merge(install_apt: fields[:install], install_apk: fields[:install]).except(:install) if fields.key?(:install) # one install line for both bases
    fields.each do |column, want|
      have = row[column.to_s]
      ok = want.is_a?(Regexp) ? have.to_s.match?(want) : have == want
      assert ok, "Expected agents.tsv of #{tag} to give #{agent} the column #{column} #{want.inspect}; it gives #{have.inspect}.#{transcript}"
    end
  end

  def agent_json(service, agent)
    agents = service_json(service)["agents"]
    assert agents.is_a?(Hash), "Expected the service #{service} in status --json to have an agents map (one entry per agent on for it); it has #{agents.inspect}.#{transcript}"
    agents[agent] or flunk("Expected the agents map of #{service} to have an entry for #{agent}; it has: #{agents.keys.join(", ")}.#{transcript}")
  end

  def assert_catalogue_entries(*names)
    text = work_file("agents.yml")
    data = YAML.safe_load(text)
    assert data.is_a?(Hash), "Expected agents.yml in the work folder to be a YAML map of agent name to fields."
    assert_equal names.sort, data.keys.sort, "Expected agents.yml to hold exactly the agents #{names.join(", ")}; it holds: #{data.keys.join(", ")}."
    data.each do |name, entry|
      assert entry.is_a?(Hash), "Expected the catalogue entry #{name} to be a map of fields."
      unknown = entry.keys - FIELDS
      assert unknown.empty?, "Expected the catalogue entry #{name} to use only the fields #{FIELDS.join(", ")}; it has: #{unknown.join(", ")}."
      missing = %w[install login headless_login] - entry.keys
      assert missing.empty?, "Expected the catalogue entry #{name} to state #{missing.join(", ")} (null when the vendor does not document it); the key is absent."
      above = text[0...(text.index(/^#{Regexp.escape(name)}:/) || 0)].lines.reverse.take_while { |l| l.start_with?("#") || l.strip.empty? }
      assert above.any? { |l| l.include?("https://") }, "Expected a comment above the catalogue entry #{name} citing the vendor's documentation (an https:// URL); there is none."
    end
  end

  def assert_catalogue_version(*names)
    data = YAML.safe_load(work_file("agents.yml"))
    names.each do |name|
      entry = data[name] or flunk("Expected the catalogue to have #{name}.")
      assert entry.key?("version"), "Expected the catalogue entry #{name} to state version, a shell line that prints the CLI's version (null when the vendor documents none); the key is absent."
      v = entry["version"]
      assert v.nil? || (v.is_a?(String) && !v.strip.empty?), "Expected #{name}'s version to be a shell line; it is #{v.inspect}."
    end
  end

  def assert_catalogue_factory_login(name, path:, create:)
    entry = YAML.safe_load(work_file("agents.yml"))[name] or flunk("Expected the catalogue to have #{name}.")
    assert_equal({ "path" => path, "create" => create }, entry["factory_login"], "Expected the catalogue entry #{name} to declare factory_login: {path: #{path}, create: #{create}}.")
  end

  def assert_catalogue_headless(*names)
    data = YAML.safe_load(work_file("agents.yml"))
    names.each do |name|
      entry = data[name] or flunk("Expected the catalogue to have #{name}.")
      assert entry.key?("headless"), "Expected the catalogue entry #{name} to state headless (null when the vendor documents no unattended run); the key is absent."
      h = entry["headless"]
      next if h.nil?
      assert h.is_a?(Hash) && h["command"].is_a?(String) && !h["command"].empty?, "Expected #{name}'s headless to give a command; it is #{h.inspect}."
      assert %w[stdin argument].include?(h["prompt"]), "Expected #{name}'s headless prompt to be stdin or argument; it is #{h["prompt"].inspect}."
    end
  end

  # Real Docker only (AgentCliIntegrationTest).
  def assert_runs_as_dev(container, line)
    out, status = Open3.capture2e({ "PATH" => ENV.fetch("PATH").split(":").reject { |p| p == Farmy::FAKES }.join(":") },
      "docker", "exec", "-u", "dev", container, "sh", "-lc", line)
    assert status.success?, "Expected `#{line}` to run as dev in #{container}; it exited #{status.exitstatus}: #{out}"
  end

  def assert_outside_homes(container, cli)
    path = real_docker("exec", "-u", "dev", container, "sh", "-lc", "readlink -f \"$(command -v #{cli})\"").strip
    refute_empty path, "Expected #{cli} on dev's PATH in #{container}."
    refute path.match?(%r{\A/(root|home)(/|\z)}), "Expected #{cli} to live outside every home directory (not under /root or /home); it resolves to #{path}."
  end

  def assert_output_names(*words)
    words.each { |w| assert_includes stdout + stderr, w, "Expected the output to name #{w.inspect}.#{transcript}" }
  end

  def refute_output_names(text, because:)
    refute_includes stdout + stderr, text, "Expected the output not to hold #{text.inspect}: #{because}.#{transcript}"
  end

  HOME_PATTERN =%r{\bsu\b[^|;&]*\bdev\b|\brunuser\b|\bgosu\s+dev\b|\bsu-exec\s+dev\b|/root\b|/home/|~/|\$HOME\b|\$\{HOME\b}

  def assert_catalogue_installs_outside_homes
    data = YAML.safe_load(work_file("agents.yml"))
    offending = data.flat_map do |name, entry|
      install = entry["install"]
      lines = install.is_a?(Hash) ? install.to_a : [["install", install]]
      lines.select { |_, line| line.is_a?(String) && line.match?(HOME_PATTERN) }.map { |base, line| "#{name} (#{base}): #{line}" }
    end
    assert offending.empty?, "Expected every catalogue agent to install its CLI outside any home directory, as root, owned by root and executable by all: no install line that runs as dev (su dev, runuser, gosu) or names /root, /home, ~ or $HOME. A CLI under a home directory is not runnable by dev (root's home is closed to others) or is hidden by a volume mounted there. Offending lines:\n  #{offending.join("\n  ")}"
  end

  PIPE_INTO_SHELL = /\b(?:curl|wget)\b[^|;&]*\|\s*(?:\w+=\S*\s+)*(?:sudo\s+)?(?:sh|bash|dash|ash|zsh)\b/

  def assert_catalogue_installs_download_then_run
    data = YAML.safe_load(work_file("agents.yml"))
    offending = data.flat_map do |name, entry|
      install = entry["install"]
      lines = install.is_a?(Hash) ? install.to_a : [["install", install]]
      lines.select { |_, line| line.is_a?(String) && line.match?(PIPE_INTO_SHELL) }.map { |base, line| "#{name} (#{base}): #{line}" }
    end
    assert offending.empty?, "Expected no catalogue install line to pipe a download into a shell (curl … | sh): a failed download then runs an empty script and the install step passes. Download to a file first and run it (curl -fsSL -o <file> <url> && sh <file>), so a failed download fails the install step with curl's own message. (set -o pipefail is no way out: Debian's sh, dash, does not have it.) Offending lines:\n  #{offending.join("\n  ")}"
  end

  # Every agent install line in a guide's code blocks keeps the catalogue's install rules: as root, outside any home,
  # download then run.
  def assert_guide_installs_keep_the_catalogue_rules(path)
    blocks = work_file(path).scan(/^```[a-z]*\n(.*?)^```/m).flatten
    lines = blocks.flat_map { |block| block.scan(/^\s*(?:install|apt|apk):[ \t]*(\S.*)$/).flatten }.reject { |l| l.strip.match?(/\A(?:~|null)?\z/) }
    refute_empty lines, "Expected the guide #{path} to show at least one agent install line in a code block."
    offending = lines.select { |l| l.match?(HOME_PATTERN) || l.match?(PIPE_INTO_SHELL) }
    assert offending.empty?, "Expected every install line the guide #{path} shows to keep the catalogue's rules: run as root, put the CLI outside any home directory (no su dev, /root, /home, ~ or $HOME), and download to a file before running it (no curl … | sh). Offending lines:\n  #{offending.join("\n  ")}"
  end

  def assert_toolbox_version_check_limited_to_30_s(service)
    commands = toolbox_build_observation(toolbox_build(service)).fetch(:commands)
    limited = commands.any? { |words| File.basename(words.first.to_s) == "timeout" && words.drop(1).find { |w| !w.start_with?("-") }.to_s.match?(/\A30s?\z/) }
    assert limited, "Expected farmy's toolbox build of farmy/#{service}:dev to give each agent's as-dev version check 30 s (timeout 30 …), so a version command that never answers fails the build, naming the agent and the 30 s limit, instead of hanging it. No step of the build (the Dockerfile and the scripts it runs) runs a command under timeout 30.#{transcript}"
  end

  def assert_toolbox_runs_a_step_as_dev(service)
    build = toolbox_build(service)
    lines = build.fetch("dockerfile").gsub(/\\\r?\n\s*/, " ").lines
    after_user_dev = lines.drop_while { |l| !l.match?(/\A\s*USER\s+(dev|1001)\b/i) }.drop(1).any? { |l| l.match?(/\A\s*RUN\s/i) }
    through_dev = toolbox_build_observation(build).fetch(:commands).any? do |words|
      %w[su runuser gosu su-exec setpriv sudo].include?(File.basename(words.first.to_s)) &&
        words.any? { |w| w.match?(/\A(?:dev|1001|--reuid=1001|--reuid=dev)\z/) }
    end
    assert after_user_dev || through_dev, "Expected farmy's toolbox build of farmy/#{service}:dev, once the agents are installed, to run each agent's version line (agents.tsv's version column) as dev, so a CLI dev cannot run fails the build, naming the agent and what the command said: a RUN after USER dev, or a command run through su/runuser/gosu/setpriv as dev. No step of the build (the Dockerfile and the scripts it runs) runs as dev.#{transcript}"
  end
end
