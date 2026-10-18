# The stranger: a Linux host with Docker Engine, repositories on GitHub over https with a token route,
# Claude Code with an API key, no mesh, no secrets manager (the secret service, or a prompt). Each step
# they take, through the shim and the fake docker.
class StrangerTest < AcceptanceTest
  def setup = workspace("workshop") # shop: https://github.com/acme/shop.git on ruby:3.4; no farmy.yml

  test "without a provider farmy unlock-names lists the routes' secrets, so the host is asked for each" do
    write_file "farmy.yml", fixture("farmy/stranger.yml") # no secrets:; routes github (GITHUB_TOKEN) and anthropic (ANTHROPIC_API_KEY); claude in api-key mode

    farmy "unlock-names"

    assert_success
    assert_stdout_is "GITHUB_TOKEN\nANTHROPIC_API_KEY\n"
  end

  test "the shim obtains the GitHub token and the API key from the secret service and hands both to farmy" do
    shim "init"
    write_file "farmy.yml", fixture("farmy/stranger.yml")
    secret_service "farmy farmy/GITHUB_TOKEN" => "ghp_7Hq2xV9c", "farmy farmy/ANTHROPIC_API_KEY" => "sk-ant-api03-4f9e"

    shim "start", "shop"

    assert_passed_to_farmy "GITHUB_TOKEN=ghp_7Hq2xV9c"
    assert_passed_to_farmy "ANTHROPIC_API_KEY=sk-ant-api03-4f9e"
  end

  test "start loads both secrets into the broker before the clone, and the repository clones through the token route" do
    write_file "farmy.yml", fixture("farmy/stranger.yml")

    farmy "start", "shop", stdin: "GITHUB_TOKEN=ghp_7Hq2xV9c\nANTHROPIC_API_KEY=sk-ant-api03-4f9e\n"

    assert_success
    assert_loaded_since_start "shop-keys", "GITHUB_TOKEN", "ANTHROPIC_API_KEY"
    assert_env "shop", "DEV_GIT_ROUTES", "https://github.com=http://keys:9181/github/"
    refute_secret_anywhere "ghp_7Hq2xV9c"
  end

  test "after start farmy keys reads both routes loaded" do
    write_file "farmy.yml", fixture("farmy/stranger.yml")
    farmy "start", "shop", stdin: "GITHUB_TOKEN=ghp_7Hq2xV9c\nANTHROPIC_API_KEY=sk-ant-api03-4f9e\n"

    farmy "keys"

    assert_stdout(/^github\s.*\bloaded\b/)
    assert_stdout(/^anthropic\s.*\bloaded\b/)
  end

  test "Claude in api-key mode from farmy.yml gets the base URL and the placeholder from the anthropic route, and no token" do
    write_file "farmy.yml", fixture("farmy/stranger.yml")

    farmy "start", "shop", stdin: "GITHUB_TOKEN=ghp_7Hq2xV9c\nANTHROPIC_API_KEY=sk-ant-api03-4f9e\n"

    assert_env "shop", "ANTHROPIC_BASE_URL", "http://keys:9181/anthropic"
    assert_env "shop", "ANTHROPIC_API_KEY", "via-farmy-keys"
    refute_env "shop", "CLAUDE_CODE_OAUTH_TOKEN"
    refute_secret_anywhere "sk-ant-api03-4f9e"
  end

  test "with no value given farmy keys reads both routes locked, not off" do
    write_file "farmy.yml", fixture("farmy/stranger.yml")
    farmy "start", "shop"

    farmy "keys"

    assert_stdout(/^github\s.*\blocked\b/)
    assert_stdout(/^anthropic\s.*\blocked\b/)
  end

  test "with no value given start goes on and warns that only public repositories clone from github.com until GITHUB_TOKEN is given" do
    write_file "farmy.yml", fixture("farmy/stranger.yml")

    farmy "start", "shop" # shop's repository is public

    assert_success
    assert_stderr "public repositories"
    assert_stderr "github.com"
    assert_stderr "GITHUB_TOKEN"
  end

  test "a private repository with no value given ends at the clone, naming the route's state and farmy keys reload" do
    write_file "farmy.yml", fixture("farmy/stranger.yml")
    private_repository "shop"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "locked"
    assert_stderr "farmy keys reload"
    assert_running "shop"
  end

  test "a token GitHub refuses ends start saying the host refused the route's secret, by name" do
    write_file "farmy.yml", fixture("farmy/stranger.yml")
    clone_fails "shop", "Cloning into '/workspace'...\nremote: Invalid username or token. Password authentication is not supported for Git operations.\nfatal: Authentication failed for 'https://github.com/acme/shop.git/'"

    farmy "start", "shop", stdin: "GITHUB_TOKEN=ghp_expired01\nANTHROPIC_API_KEY=sk-ant-api03-4f9e\n"

    assert_exit 1
    assert_stderr "Authentication failed"
    assert_stderr "refused"
    assert_stderr "GITHUB_TOKEN"
  end

  test "the shipped farmy.example.yml, copied as farmy.yml, starts a GitHub service with the two values on stdin" do
    write_file "farmy.yml", work_file("farmy.example.yml")

    farmy "start", "shop", stdin: "GITHUB_TOKEN=ghp_7Hq2xV9c\nANTHROPIC_API_KEY=sk-ant-api03-4f9e\n"

    assert_success
    assert_loaded_into "shop-keys", "GITHUB_TOKEN", "ANTHROPIC_API_KEY"
  end
end
