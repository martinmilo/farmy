# The guides the work folder ships, held to what was decided: a reader of the credentials guide
# learns the rule before the platforms, and every guide leads with the stranger (Docker Engine, a
# token route, a prompt, no mesh); the owner's setup is one worked example at the end.
class DocsTest < AcceptanceTest
  test "the credentials guide states that farmy never stores a secret on disk, and shows how to add an entry to both stores" do
    assert_guide_says "docs/credentials.md", "never stores a secret on disk", "FARMY_SECRET_PREFIX", "FARMY_UNLOCK_COMMAND",
                      "security add-generic-password", "-T /usr/bin/security", "secret-tool store"
  end

  test "getting started leads with Docker Engine, the token route, the prompt and no mesh, and points at the worked example last" do
    assert_guide_orders "docs/getting-started.md", "Docker Engine", "Docker Desktop"
    assert_guide_orders "docs/getting-started.md", "auth: basic", "auth: ssh"
    assert_guide_orders "docs/getting-started.md", "prompt", "secret-tool", "Keychain"
    assert_guide_orders "docs/getting-started.md", "mode: api-key", "egress:"
    assert_last_link "docs/getting-started.md", "worked-example.md"
  end

  test "the credentials guide shows the token route before the SSH route, and the prompt and the secret service before the Keychain" do
    assert_guide_orders "docs/credentials.md", "auth: basic", "auth: ssh"
    assert_guide_orders "docs/credentials.md", "prompt", "secret-tool store", "security add-generic-password"
    assert_guide_orders "docs/credentials.md", "providers/env", "providers/infisical"
  end

  test "the worked example carries the macOS, Infisical, Headscale and SSH-port setup with example.com names, and first-run.md is gone" do
    assert_guide_says "docs/worked-example.md", "Keychain", "--client-id-from", "Headscale", "login_server", ":2222", "encoding: base64", "example.com"
    refute_work_file "docs/first-run.md"
  end

  test "the factory guide shows how to pin the model, the effort and the CLI version through the agent entry, with Codex's flags and Claude's effort variable, and points at the run record" do
    assert_guide_says "docs/factory.md", "codex exec -m ", "-c model_reasoning_effort=", "CODEX_RELEASE=0.163.0",
                      "CLAUDE_CODE_EFFORT_LEVEL", "agent_version", "farmy rebuild"
  end

  test "the factory guide names no Codex reasoning-effort flag, since Codex 0.163.0 has none" do
    refute_guide_says "docs/factory.md", "--reasoning-effort", "--model-reasoning-effort"
  end

  test "the factory guide's Codex pin is a farmy.yml agent entry that farmy accepts as written" do
    write_file "farmy.yml", guide_yaml_block("docs/factory.md", holding: "CODEX_RELEASE=0.163.0")

    farmy "agents"

    assert_success
    assert_stdout(/^codex\s+on\s/)
  end

  test "the getting-started guide says that WSL2 with Docker Desktop is unverified" do
    assert_guide_says "docs/getting-started.md", "WSL2", "unverified"
  end
end
