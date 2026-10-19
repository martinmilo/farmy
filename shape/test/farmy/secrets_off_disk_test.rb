# No secret's value in a file farmy writes. An agent's token_env secret reaches the app container's environment
# (the documented exception), but compose.yml names the variable only (environment: [NAME], or NAME: ${NAME})
# and farmy gives the value in the environment of docker compose at every compose up. Each test's values are
# its own (secret_value).
class SecretsOffDiskTest < AcceptanceTest
  test "in subscription mode no file farmy writes holds the provider's token, and the app container still has it" do
    workspace "workshop"
    write_file "farmy.yml", fixture("farmy/claude.yml")
    token = secret_value("sk-ant-oat01")
    secrets_provider CLAUDE_CODE_OAUTH_TOKEN: token, ANTHROPIC_API_KEY: secret_value("sk-ant-api03")

    farmy "start", "shop"

    assert_success
    assert_env "shop", "CLAUDE_CODE_OAUTH_TOKEN", token
    refute_in_files_farmy_wrote token
  end

  test "the app's compose file names the token's variable without its value" do
    workspace "workshop"
    write_file "farmy.yml", fixture("farmy/claude.yml")
    secrets_provider CLAUDE_CODE_OAUTH_TOKEN: secret_value("sk-ant-oat01"), ANTHROPIC_API_KEY: secret_value("sk-ant-api03")

    farmy "start", "shop"

    assert_success
    assert_compose_names_without_value "shop", "CLAUDE_CODE_OAUTH_TOKEN"
  end

  test "after farmy restart the app container still gets the provider's token" do
    workspace "workshop"
    write_file "farmy.yml", fixture("farmy/claude.yml")
    token = secret_value("sk-ant-oat01")
    secrets_provider CLAUDE_CODE_OAUTH_TOKEN: token, ANTHROPIC_API_KEY: secret_value("sk-ant-api03")
    farmy "start", "shop"

    farmy "restart", "shop"

    assert_success
    assert_env "shop", "CLAUDE_CODE_OAUTH_TOKEN", token
    refute_in_files_farmy_wrote token
  end

  test "a token from an unlocking value stays out of every file farmy writes, and after farmy restart without the value given again the app container still gets it from the held values" do
    token = secret_value("sk-ant-oat01")
    factory_service model: :token, token: token

    farmy "restart", "shop"

    assert_success
    assert_env "shop", "CLAUDE_CODE_OAUTH_TOKEN", token
    refute_in_files_farmy_wrote token
  end

  test "after farmy stop and farmy start, which reuses the app's compose file, the app container still gets the provider's token" do
    workspace "workshop"
    write_file "farmy.yml", fixture("farmy/claude.yml")
    token = secret_value("sk-ant-oat01")
    secrets_provider CLAUDE_CODE_OAUTH_TOKEN: token, ANTHROPIC_API_KEY: secret_value("sk-ant-api03")
    farmy "start", "shop"
    farmy "stop", "shop"

    farmy "start", "shop"

    assert_success
    assert_env "shop", "CLAUDE_CODE_OAUTH_TOKEN", token
    refute_in_files_farmy_wrote token
  end
end
