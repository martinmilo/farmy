# No secret's value on a command line: while a factory run goes, no process farmy starts (every docker call,
# every command a container runs) shows a secret's value in its argv. Docker takes a value as -e NAME without
# a value, from the environment farmy gives the docker process, or from a 0600 --env-file farmy deletes once
# the container has started. Each test gives start values of its own (secret_value), so no other test's
# processes can show them.
class SecretsOffCommandLinesTest < AcceptanceTest
  test "in token mode no process farmy starts during a run has the token's value on its command line, and the agent still gets the token" do
    token = secret_value("sk-ant-oat01")
    factory_service model: :token, max_iterations: 1, token: token
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    watch_command_lines { factory_start }

    assert_success
    assert_no_command_line_holds "CLAUDE_CODE_OAUTH_TOKEN", token
    assert_run_env "agent", "CLAUDE_CODE_OAUTH_TOKEN", token
  end

  test "in api-key mode with mesh egress no process farmy starts during a run has the route's key or the mesh auth key on its command line" do
    key = secret_value("sk-ant-api03")
    authkey = secret_value("tskey-auth")
    factory_service model: :api, egress: true, max_iterations: 1, api_key: key, authkey: authkey
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    watch_command_lines { factory_start }

    assert_success
    assert_no_command_line_holds "ANTHROPIC_API_KEY", key
    assert_no_command_line_holds "TS_AUTHKEY", authkey
  end

  test "every env file farmy hands Docker during a run is readable by its owner only, and gone while the agent still runs" do
    factory_service model: :token, max_iterations: 1, token: secret_value("sk-ant-oat01")
    agent_plays({ barrier: "token-agent", writes: { "src/app.txt" => "fixed\n" } })
    factory_start wait: false
    id = run_id

    wait_agent_barrier "token-agent"
    assert_env_files_private_and_gone
    release_agent_barrier "token-agent"

    wait_run id, result: "green"
    assert_env_files_private_and_gone
  end
end
