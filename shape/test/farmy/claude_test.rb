# Claude through the catalogue: the same rules as any agent (agents_test.rb), seen on the shipped entry.
class ClaudeTest < AcceptanceTest
  def setup = workspace("workshop") # shop and notes; farmy.yml from the fixture: claude in subscription mode, an anthropic route

  test "in subscription mode the app container gets the Claude token and none of Claude's api variables" do
    write_file "farmy.yml", fixture("farmy/claude.yml")
    secrets_provider CLAUDE_CODE_OAUTH_TOKEN: "sk-ant-oat01-9f2c", ANTHROPIC_API_KEY: "sk-ant-7f3a9c"

    farmy "start", "shop"

    assert_env "shop", "CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-9f2c"
    refute_env "shop", "ANTHROPIC_BASE_URL"
    refute_env "shop", "ANTHROPIC_API_KEY"
  end

  test "in api-key mode the app container gets the base URL and the placeholder from the anthropic route, and no token" do
    write_file "farmy.yml", fixture("farmy/claude.yml")
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nagents: {claude: api-key}\n"
    secrets_provider CLAUDE_CODE_OAUTH_TOKEN: "sk-ant-oat01-9f2c", ANTHROPIC_API_KEY: "sk-ant-7f3a9c"

    farmy "start", "shop"

    assert_env "shop", "ANTHROPIC_BASE_URL", "http://keys:9181/anthropic"
    assert_env "shop", "ANTHROPIC_API_KEY", "via-farmy-keys"
    refute_env "shop", "CLAUDE_CODE_OAUTH_TOKEN"
    refute_secret_anywhere "sk-ant-7f3a9c"
  end

  test "each service keeps its agents' state on a volume of its own under .farmy-service, and shares the logins through farmy-shared" do
    write_file "farmy.yml", "agents:\n  claude: {}\n"
    farmy "start", "notes" # starts shop first

    assert_mounted "shop", "shop-agents", at: "/home/dev/.farmy-service"
    assert_mounted "notes", "notes-agents", at: "/home/dev/.farmy-service"
    assert_mounted "shop", "farmy-shared", at: "/home/dev/.farmy-shared"
    assert_agent_built "shop", "claude", state: "projects" # ~/.claude/projects is a link into .farmy-service/claude
  end

  test "a service with claude off gets neither the token nor Claude in its image" do
    write_file "farmy.yml", fixture("farmy/claude.yml")
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nagents: {claude: off}\n"
    secrets_provider CLAUDE_CODE_OAUTH_TOKEN: "sk-ant-oat01-9f2c"

    farmy "start", "shop"

    refute_env "shop", "CLAUDE_CODE_OAUTH_TOKEN"
    assert_built with_arg: "AGENTS="
    refute_mounted "shop", "shop-agents"
  end
end
