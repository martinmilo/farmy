# Agents as data: the shipped catalogue (agents.yml in the work folder), entries of your own under
# agents: in farmy.yml, and what the toolbox build and the entrypoint are given about each agent.
#
#   assert_agent_built "shop", "mytool", install: "npm install -g mytool@2.4.0", login: ".mytool"
#                                       the agents.tsv in the build context of farmy/shop:dev gives the agent these columns
#   assert_agent_built "shop", "cursor", install_apt: /cursor.com\/install/, install_apk: ""   an install line per base
#   agent_json "shop", "claude"              one agent's entry in the service's agents map of farmy status --json
#   assert_catalogue_entries "claude", "codex", …
#                                       agents.yml holds exactly these, known fields only, a documentation URL in a comment above each
require "yaml"

module Agents
  FIELDS = %w[install login state headless_login headless token_env env api api_hosts mcp_add status_hooks process mode].freeze
  COLUMNS = %w[name install_apt install_apk login state mcp_add hooks_file hooks_events process].freeze

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
end
