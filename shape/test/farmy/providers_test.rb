# The two providers farmy ships, run as programs through farmy (providers/env, providers/infisical).
class ProvidersTest < AcceptanceTest
  def setup = workspace("workshop") # shop, notes, toolkit; no farmy.yml

  test "providers/env answers with the unlocking values farmy was given and reports the rest missing" do
    write_file "farmy.yml", fixture("farmy/keys.yml").sub("provider: [bin/provider]", "provider: [providers/env]\n  unlock: [GIT_TOKEN]")

    farmy "start", "shop", stdin: "GIT_TOKEN=frg_9c1e5d7b2a\n"

    assert_success
    assert_loaded_into "shop-keys", "GIT_TOKEN"
    refute_loaded_into "shop-keys", "ANTHROPIC_API_KEY"
    refute_secret_anywhere "frg_9c1e5d7b2a"
  end

  test "providers/infisical asks the infisical CLI for each secret with the arguments of farmy.yml and the unlocking token in its environment" do
    write_file "farmy.yml", fixture("farmy/keys.yml").sub("provider: [bin/provider]", "provider: [providers/infisical, --projectId, p-4711, --env, dev]\n  unlock: [INFISICAL_TOKEN]")
    log = File.join(dir, "infisical.log")

    farmy "start", "shop", stdin: "INFISICAL_TOKEN=st.d41d8cd9\n",
          env: { "FAKE_INFISICAL_SECRETS" => "GIT_TOKEN=frg_9c1e5d7b2a;ANTHROPIC_API_KEY=sk-ant-7f3a9c", "FAKE_INFISICAL_LOG" => log }

    assert_success
    assert_loaded_into "shop-keys", "GIT_TOKEN", "ANTHROPIC_API_KEY"
    assert_file "infisical.log", includes: "args: secrets get GIT_TOKEN --plain --projectId p-4711 --env dev"
    assert_file "infisical.log", includes: "token: st.d41d8cd9"
    refute_secret_anywhere "st.d41d8cd9"
  end

  test "providers/infisical reports a secret the CLI does not have as missing" do
    write_file "farmy.yml", fixture("farmy/keys.yml").sub("provider: [bin/provider]", "provider: [providers/infisical]\n  unlock: [INFISICAL_TOKEN]")
    farmy "start", "shop", stdin: "INFISICAL_TOKEN=st.d41d8cd9\n", env: { "FAKE_INFISICAL_SECRETS" => "GIT_TOKEN=frg_9c1e5d7b2a" }
    assert_success
    refute_loaded_into "shop-keys", "ANTHROPIC_API_KEY"

    farmy "keys"

    assert_stdout(/^git\s.*loaded/)
    assert_stdout(/^anthropic\s.*missing/)
  end
  test "providers/infisical with --client-id-from and --client-secret-from logs in with universal auth and uses the token for every get, with nothing on a command line" do
    write_file "farmy.yml", fixture("farmy/keys.yml").sub("provider: [bin/provider]", "provider: [providers/infisical, --client-id-from, INFISICAL_CLIENT_ID, --client-secret-from, INFISICAL_CLIENT_SECRET, --projectId, p-4711, --env, dev]\n  unlock: [INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET]")
    log = File.join(dir, "infisical.log")

    farmy "start", "shop", stdin: "INFISICAL_CLIENT_ID=5b0c7e1d-2f3a\nINFISICAL_CLIENT_SECRET=cs_9e2f4b7a1c\n",
          env: { "FAKE_INFISICAL_IDENTITIES" => "5b0c7e1d-2f3a:cs_9e2f4b7a1c=st.u-91ab3c", "FAKE_INFISICAL_SECRETS" => "GIT_TOKEN=frg_9c1e5d7b2a;ANTHROPIC_API_KEY=sk-ant-7f3a9c", "FAKE_INFISICAL_LOG" => log }

    assert_success
    assert_loaded_into "shop-keys", "GIT_TOKEN", "ANTHROPIC_API_KEY"
    assert_file "infisical.log", includes: "args: login --method=universal-auth --plain\n"
    assert_file "infisical.log", includes: "identity: 5b0c7e1d-2f3a cs_9e2f4b7a1c"
    assert_file "infisical.log", includes: "args: secrets get GIT_TOKEN --plain --projectId p-4711 --env dev\ntoken: st.u-91ab3c"
    refute_secret_anywhere "cs_9e2f4b7a1c"
    refute_secret_anywhere "st.u-91ab3c"
  end

  test "providers/infisical passes --domain to the login and to every get" do
    write_file "farmy.yml", fixture("farmy/keys.yml").sub("provider: [bin/provider]", "provider: [providers/infisical, --client-id-from, INFISICAL_CLIENT_ID, --client-secret-from, INFISICAL_CLIENT_SECRET, --domain, https://secrets.example.com, --env, dev]\n  unlock: [INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET]")
    log = File.join(dir, "infisical.log")

    farmy "start", "shop", stdin: "INFISICAL_CLIENT_ID=5b0c7e1d-2f3a\nINFISICAL_CLIENT_SECRET=cs_9e2f4b7a1c\n",
          env: { "FAKE_INFISICAL_IDENTITIES" => "5b0c7e1d-2f3a:cs_9e2f4b7a1c=st.u-91ab3c", "FAKE_INFISICAL_SECRETS" => "GIT_TOKEN=frg_9c1e5d7b2a", "FAKE_INFISICAL_LOG" => log }

    assert_success
    assert_file "infisical.log", includes: "args: login --method=universal-auth --plain --domain https://secrets.example.com\n"
    assert_file "infisical.log", includes: "args: secrets get GIT_TOKEN --plain --domain https://secrets.example.com --env dev\n"
  end

  test "providers/infisical with an identity Infisical rejects reports provider failed and shows nothing" do
    write_file "farmy.yml", fixture("farmy/keys.yml").sub("provider: [bin/provider]", "provider: [providers/infisical, --client-id-from, INFISICAL_CLIENT_ID, --client-secret-from, INFISICAL_CLIENT_SECRET]\n  unlock: [INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET]")
    farmy "start", "shop", stdin: "INFISICAL_CLIENT_ID=5b0c7e1d-2f3a\nINFISICAL_CLIENT_SECRET=cs_wrong\n",
          env: { "FAKE_INFISICAL_IDENTITIES" => "5b0c7e1d-2f3a:cs_9e2f4b7a1c=st.u-91ab3c" }
    assert_success
    refute_stderr "unable to authenticate"

    farmy "keys"

    assert_stdout(/^git\s.*provider failed/)
    refute_stdout "unable to authenticate"
  end

  test "with egress the Infisical CLI reaches its domain through the HTTP CONNECT proxy" do
    infisical = fake_upstream
    proxy = fake_proxy
    write_file "farmy.yml", fixture("farmy/keys.yml").sub("provider: [bin/provider]", "provider: [providers/infisical, --domain, #{infisical.url}, --env, dev]\n  unlock: [INFISICAL_TOKEN, TS_AUTHKEY]") + "egress:\n  authkey: TS_AUTHKEY\n"
    log = File.join(dir, "infisical.log")

    farmy "start", "shop", stdin: "INFISICAL_TOKEN=st.d41d8cd9\nTS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n",
          env: { "FARMY_EGRESS_PROXY" => proxy.url.delete_prefix("http://"), "FAKE_INFISICAL_SECRETS" => "GIT_TOKEN=frg_9c1e5d7b2a", "FAKE_INFISICAL_LOG" => log }

    assert_success
    assert_includes proxy.targets, infisical.url.sub("http://", "https://")
    assert_loaded_into "shop-keys", "GIT_TOKEN"
  end

  test "keys --why with the Infisical provider shows the CLI's own error, redacted" do
    write_file "farmy.yml", fixture("farmy/keys.yml").sub("provider: [bin/provider]", "provider: [providers/infisical, --env, dev]\n  unlock: [INFISICAL_TOKEN]")

    farmy "keys", "--why", stdin: "INFISICAL_TOKEN=st.d41d8cd9\n", env: { "FAKE_INFISICAL_SECRETS" => "GIT_TOKEN=frg_9c1e5d7b2a" }

    assert_success
    assert_stdout "Error: secret ANTHROPIC_API_KEY not found"
    refute_stdout "frg_9c1e5d7b2a"
    refute_stdout "st.d41d8cd9"
  end

  test "providers/env answers a multi-line secret as valid JSON, byte for byte" do
    write_file "farmy.yml", fixture("farmy/keys-ssh.yml").sub("provider: [bin/provider]", "provider: [providers/env]\n  unlock: [GIT_SSH_KEY]")

    farmy "start", "shop", stdin: "GIT_SSH_KEY:base64=#{[fixture("keys/git_ed25519")].pack("m0")}\n"

    assert_success
    assert_equal fixture("keys/git_ed25519"), value_loaded_into("shop-keys", "GIT_SSH_KEY")
  end

  test "providers/infisical answers a multi-line secret as valid JSON, byte for byte" do
    write_file "farmy.yml", fixture("farmy/keys-ssh.yml").sub("provider: [bin/provider]", "provider: [providers/infisical]\n  unlock: [INFISICAL_TOKEN]")
    write_file "vault/GIT_SSH_KEY", fixture("keys/git_ed25519")

    farmy "start", "shop", stdin: "INFISICAL_TOKEN=st.d41d8cd9\n", env: { "FAKE_INFISICAL_SECRETS_DIR" => File.join(dir, "vault") }

    assert_success
    assert_equal fixture("keys/git_ed25519").chomp, value_loaded_into("shop-keys", "GIT_SSH_KEY").chomp
  end
end
