# Agents as data: the shipped catalogue (agents.yml), entries of your own under agents: in farmy.yml with
# the same fields, a mode per agent and per service. Claude is one catalogue entry like any other.
class AgentsTest < AcceptanceTest
  def setup = workspace("workshop") # shop, notes, toolkit; no farmy.yml: no agent on

  test "the shipped catalogue has claude, codex, gemini, opencode, cursor and copilot, with known fields only and the vendor's documentation cited above each" do
    assert_catalogue_entries "claude", "codex", "gemini", "opencode", "cursor", "copilot"
  end

  test "farmy agents lists every agent, on or off, with its mode and how to log in without a browser" do
    write_file "farmy.yml", "agents:\n  claude: {}\n"

    farmy "agents"

    assert_success
    assert_stdout(/^claude\s+on\s+subscription\s+claude setup-token/)
    assert_stdout(/^codex\s+off\s+subscription\s+codex login --device-auth/)
    %w[gemini opencode cursor copilot].each { |name| assert_stdout(/^#{name}\s+off\s/) }
  end

  test "an agent of your own is installed by the toolbox from its install command, like a shipped one" do
    write_file "farmy.yml", fixture("farmy/agents-mytool.yml") # claude from the catalogue, mytool with every field

    farmy "start", "shop"

    assert_built with_arg: "AGENTS=claude mytool"
    assert_agent_built "shop", "mytool", install: "npm install -g mytool@2.4.0"
    assert_agent_built "shop", "claude", install: /claude/
  end

  test "an agent of your own has its login paths linked into farmy-shared and is named to the entrypoint, like a shipped one" do
    write_file "farmy.yml", fixture("farmy/agents-mytool.yml")

    farmy "start", "shop"

    assert_agent_built "shop", "mytool", login: ".mytool/"
    assert_agent_built "shop", "claude", login: /\.claude/
    assert_env "shop", "FARMY_AGENTS", "claude mytool"
    assert_mounted "shop", "farmy-shared", at: "/home/dev/.farmy-shared"
  end

  test "an agent of your own in api-key mode gets its base URL and key variables from the route with its upstream" do
    write_file "farmy.yml", fixture("farmy/agents-mytool.yml").sub("    process: mytool\n", "    process: mytool\n    mode: api-key\n")
    secrets_provider MYTOOL_API_KEY: "mt_4e7b1c9d"

    farmy "start", "shop"

    assert_env "shop", "MYTOOL_BASE_URL", "http://keys:9181/mytool"
    assert_env "shop", "MYTOOL_API_KEY", "via-farmy-keys"
    refute_env "shop", "MYTOOL_TOKEN"
    refute_secret_anywhere "mt_4e7b1c9d"
  end

  test "in subscription mode an agent with a token_env gets that secret in its environment and none of its api variables" do
    write_file "farmy.yml", fixture("farmy/agents-mytool.yml")
    secrets_provider MYTOOL_TOKEN: "mt-oauth-91ab3c", MYTOOL_API_KEY: "mt_4e7b1c9d"

    farmy "start", "shop"

    assert_env "shop", "MYTOOL_TOKEN", "mt-oauth-91ab3c"
    refute_env "shop", "MYTOOL_BASE_URL"
    refute_env "shop", "MYTOOL_API_KEY"
  end

  test "api-key mode for an agent with no route to its upstream is refused, naming the agent and the upstream" do
    write_file "farmy.yml", fixture("farmy/agents-mytool.yml").sub("    process: mytool\n", "    process: mytool\n    mode: api-key\n").sub("    upstream: https://api.mytool.example\n    auth: header", "    upstream: https://api.other.example\n    auth: header")

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "mytool"
    assert_stderr "https://api.mytool.example"
    refute_container "shop"
  end

  test "an agent entry with an unknown field is refused by name" do
    write_file "farmy.yml", "agents:\n  mytool:\n    install: npm install -g mytool\n    logn: .mytool\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "farmy.yml"
    assert_stderr "logn"
    refute_container "shop"
  end

  test "a catalogue entry overridden in one field keeps the catalogue's other fields" do
    write_file "farmy.yml", "agents:\n  claude:\n    install: npm install -g @anthropic-ai/claude-code@2.0.0\n"

    farmy "start", "shop"

    assert_agent_built "shop", "claude", install: "npm install -g @anthropic-ai/claude-code@2.0.0", login: /\.claude/
  end

  test "the old claude key in farmy.yml is refused and points at agents" do
    write_file "farmy.yml", "claude:\n  mode: api-key\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "farmy.yml"
    assert_stderr "agents"
    refute_container "shop"
  end

  test "an agent switched off for one service is not installed in its image and gets none of its variables" do
    write_file "farmy.yml", fixture("farmy/agents-mytool.yml")
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nagents: {mytool: off}\n"
    secrets_provider MYTOOL_TOKEN: "mt-oauth-91ab3c"

    farmy "start", "shop"

    assert_built with_arg: "AGENTS=claude"
    assert_env "shop", "FARMY_AGENTS", "claude"
    refute_env "shop", "MYTOOL_TOKEN"
  end

  test "status --json reports each agent of a service: from its hooks' status file, else from its process" do
    write_file "farmy.yml", fixture("farmy/agents-mytool.yml")
    farmy "start", "shop"
    volume_file "shop-agents", "claude/agent.status", "waiting\t2026-10-14T09:12:00Z\n"
    process_in "shop", "mytool"

    farmy "status", "--json"

    assert_equal({ "state" => "waiting", "since" => "2026-10-14T09:12:00Z", "source" => "hooks" }, agent_json("shop", "claude"))
    assert_equal({ "state" => "running", "since" => nil, "source" => "process" }, agent_json("shop", "mytool"))
  end

  test "a login path with an extension is a file and one without is a folder: agents.tsv marks folders with a slash" do
    write_file "farmy.yml", fixture("farmy/agents-mytool.yml").sub("    login: .mytool\n", "    login: [.mytool, .mytool.toml]\n")

    farmy "start", "shop"

    assert_agent_built "shop", "claude", login: ".claude/:.claude.json"
    assert_agent_built "shop", "mytool", login: ".mytool/:.mytool.toml"
  end

  test "without agents: in farmy.yml no agent is on: the image carries none and farmy agents lists every one off" do
    farmy "start", "shop"
    assert_built with_arg: "AGENTS="

    farmy "agents"

    %w[claude codex gemini opencode cursor copilot].each { |name| assert_stdout(/^#{name}\s+off\s/) }
  end

  test "every catalogue agent states how it runs headless, as a command and how the prompt is passed" do
    assert_catalogue_headless "claude", "codex", "gemini", "opencode", "cursor", "copilot"
  end

  test "every catalogue agent states its version command, a shell line that prints the CLI's version" do
    assert_catalogue_version "claude", "codex", "gemini", "opencode", "cursor", "copilot"
  end

  test "codex's catalogue entry declares its factory login: .codex, created by codex login --device-auth" do
    assert_catalogue_factory_login "codex", path: ".codex", create: "codex login --device-auth"
  end
end
