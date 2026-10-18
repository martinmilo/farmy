class KeysTest < AcceptanceTest
  def setup = workspace("workshop") # shop and toolkit on github.com, notes on codeberg.org; no key anywhere in the folder

  test "the secrets a route needs are asked from the provider by name and nothing else is asked" do
    write_file "farmy.yml", fixture("farmy/keys.yml") # routes git (GIT_TOKEN, host github.com) and anthropic (ANTHROPIC_API_KEY)
    secrets_provider GIT_TOKEN: "frg_9c1e5d7b2a", ANTHROPIC_API_KEY: "sk-ant-7f3a9c", PAYPAL_SECRET: "pp_41"

    farmy "start", "shop"

    assert_file "provider.log", includes: "asked: GIT_TOKEN ANTHROPIC_API_KEY"
  end

  test "a secret the provider returns reaches the broker on stdin and no container's environment" do
    write_file "farmy.yml", fixture("farmy/keys.yml")
    secrets_provider GIT_TOKEN: "frg_9c1e5d7b2a", ANTHROPIC_API_KEY: "sk-ant-7f3a9c"

    farmy "start", "shop"

    assert_loaded_into "shop-keys", "GIT_TOKEN", "ANTHROPIC_API_KEY"
    refute_env "shop-keys", "GIT_TOKEN"
    refute_env "shop", "ANTHROPIC_API_KEY"
  end

  test "no secret value appears in a docker command line, a generated file, farmy's state or its output" do
    write_file "farmy.yml", fixture("farmy/keys.yml")
    secrets_provider GIT_TOKEN: "frg_9c1e5d7b2a", ANTHROPIC_API_KEY: "sk-ant-7f3a9c"

    farmy "start", "shop"

    refute_secret_anywhere "frg_9c1e5d7b2a"
    refute_secret_anywhere "sk-ant-7f3a9c"
  end

  test "the app container gets the variable a route exposes, pointing at the route" do
    write_file "farmy.yml", fixture("farmy/keys.yml")
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nagents: {claude: api-key}\n" # subscription mode would keep Claude's variables out
    secrets_provider ANTHROPIC_API_KEY: "sk-ant-7f3a9c"

    farmy "start", "shop"

    assert_env "shop", "ANTHROPIC_BASE_URL", "http://keys:9181/anthropic"
    assert_env "shop-keys", "FARMY_ROUTE_ANTHROPIC", "https://api.anthropic.com header x-api-key ANTHROPIC_API_KEY"
  end

  test "a route granted to some services is in those brokers only" do
    write_file "farmy.yml", fixture("farmy/keys-granted.yml") # anthropic: services: [notes]
    secrets_provider ANTHROPIC_API_KEY: "sk-ant-7f3a9c"

    farmy "start", "notes" # starts shop first

    assert_env "notes-keys", "FARMY_ROUTES", /\banthropic\b/
    refute_env "shop-keys", "FARMY_ROUTE_ANTHROPIC"
    refute_loaded_into "shop-keys", "ANTHROPIC_API_KEY"
    refute_env "shop", "ANTHROPIC_BASE_URL"
  end

  test "a route whose secret the provider does not have is configured in the app, unloaded in the broker, and keys says missing" do
    write_file "farmy.yml", fixture("farmy/keys.yml")
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nagents: {claude: api-key}\n"
    secrets_provider GIT_TOKEN: "frg_9c1e5d7b2a"
    farmy "start", "shop"

    farmy "keys"

    assert_stdout(/^anthropic\s.*missing/)
    assert_env "shop", "ANTHROPIC_BASE_URL", "http://keys:9181/anthropic" # so that a later reload needs no new container
    assert_env "shop-keys", "FARMY_ROUTE_ANTHROPIC", /ANTHROPIC_API_KEY/
    refute_loaded_into "shop-keys", "ANTHROPIC_API_KEY"
  end

  test "a provider that fails switches its routes off, says so without its output, and start goes on to the containers" do
    write_file "farmy.yml", fixture("farmy/keys.yml")
    secrets_provider_failing "token expired at 2026-10-12"

    farmy "start", "shop"

    assert_success
    assert_stderr "bin/provider"
    refute_stderr "token expired"
    assert_running "shop"
    refute_loaded_into "shop-keys", "ANTHROPIC_API_KEY"
    refute_loaded_into "shop-keys", "GIT_TOKEN"
  end

  test "keys says provider failed for the routes of a provider that failed" do
    write_file "farmy.yml", fixture("farmy/keys.yml")
    secrets_provider_failing "token expired at 2026-10-12"
    farmy "start", "shop"

    farmy "keys"

    assert_stdout(/^anthropic\s.*provider failed/)
    assert_stdout(/^git\s.*provider failed/)
  end

  test "a provider that answers with the protocol's error form has its routes read provider failed, and the error text is not shown" do
    write_file "farmy.yml", fixture("farmy/keys.yml")
    secrets_provider_erring "vault sealed since 2026-10-12"
    farmy "start", "shop"
    assert_success
    refute_stderr "vault sealed"
    refute_loaded_into "shop-keys", "GIT_TOKEN"

    farmy "keys"

    assert_stdout(/^git\s.*provider failed/)
    refute_stdout "vault sealed"
  end

  test "an unlocking value given on stdin reaches the provider's environment and nowhere else" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml") # secrets.unlock: [INFISICAL_TOKEN]
    secrets_provider ANTHROPIC_API_KEY: "sk-ant-7f3a9c"

    farmy "start", "shop", stdin: "INFISICAL_TOKEN=inf_d41d8cd9\n"

    assert_file "provider.log", includes: "env: INFISICAL_TOKEN=inf_d41d8cd9"
    refute_secret_anywhere "inf_d41d8cd9"
  end

  test "an unlocking value not given leaves the routes locked and keys says locked" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    secrets_provider ANTHROPIC_API_KEY: "sk-ant-7f3a9c"
    farmy "start", "shop"

    farmy "keys"

    assert_stdout(/^anthropic\s.*locked/)
    refute_file "provider.log"
  end

  test "keys reload loads a missing secret into the running broker and the app keeps pointing at the route" do
    write_file "farmy.yml", fixture("farmy/keys.yml")
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nagents: {claude: api-key}\n"
    secrets_provider GIT_TOKEN: "frg_9c1e5d7b2a"
    farmy "start", "shop"
    refute_loaded_into "shop-keys", "ANTHROPIC_API_KEY"
    secrets_provider GIT_TOKEN: "frg_9c1e5d7b2a", ANTHROPIC_API_KEY: "sk-ant-7f3a9c"

    farmy "keys", "reload", "shop"

    assert_success
    assert_loaded_into "shop-keys", "ANTHROPIC_API_KEY"
    assert_env "shop", "ANTHROPIC_BASE_URL", "http://keys:9181/anthropic"
    assert_running "shop"
  end

  test "after keys reload, keys says loaded" do
    write_file "farmy.yml", fixture("farmy/keys.yml")
    secrets_provider GIT_TOKEN: "frg_9c1e5d7b2a"
    farmy "start", "shop"
    secrets_provider GIT_TOKEN: "frg_9c1e5d7b2a", ANTHROPIC_API_KEY: "sk-ant-7f3a9c"
    farmy "keys", "reload", "shop"

    farmy "keys"

    assert_stdout(/^anthropic\s.*loaded/)
  end

  test "a definition that names a route it is not granted is refused" do
    write_file "farmy.yml", fixture("farmy/keys-granted.yml") # anthropic: services: [notes]
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nkeys: [anthropic]\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "anthropic"
    assert_stderr "services/shop.yml"
    refute_container "shop"
  end
  test "an SSH git route gives the app container an agent socket and never the key" do
    write_file "farmy.yml", fixture("farmy/keys-ssh.yml") # git: secret GIT_SSH_KEY, upstream ssh://git@github.com, auth ssh
    secrets_provider GIT_SSH_KEY: fixture("keys/git_ed25519")

    farmy "start", "shop"

    assert_env "shop", "SSH_AUTH_SOCK", "/run/farmy-keys/agent.sock"
    assert_mounted "shop", "shop-keys-agent", at: "/run/farmy-keys"
    assert_loaded_into "shop-keys", "GIT_SSH_KEY"
    refute_env "shop", "GIT_SSH_KEY"
    refute_secret_anywhere "AAAAC3NzaC1lZDI1NTE5AAAAIEjn"
  end

  test "with an SSH git route for its host an https repo: is cloned over SSH, without an http rewrite, and with an insteadOf rule" do
    write_file "farmy.yml", fixture("farmy/keys-ssh.yml") # the route's host is github.com; shop's repo: is https://github.com/acme/shop.git
    secrets_provider GIT_SSH_KEY: fixture("keys/git_ed25519")

    farmy "start", "shop"

    assert_env "shop", "REPO", "ssh://git@github.com/acme/shop.git"
    refute_env "shop", "DEV_GIT_ROUTES"
    assert_env "shop", "DEV_GIT_SSH_ROUTES", "https://github.com/=ssh://git@github.com/"
  end

  test "an SSH route with a user and a port of its own has both in the clone URL and in the insteadOf rule" do
    write_file "farmy.yml", fixture("farmy/keys-ssh.yml").sub("upstream: ssh://git@github.com", "upstream: ssh://forgejo@git.example.com:2222")
    write_file "services/shop.yml", "repo: https://git.example.com/acme/shop.git\nimage: ruby:3.4\n"
    secrets_provider GIT_SSH_KEY: fixture("keys/git_ed25519")

    farmy "start", "shop"

    assert_env "shop", "REPO", "ssh://forgejo@git.example.com:2222/acme/shop.git"
    assert_env "shop", "DEV_GIT_SSH_ROUTES", "https://git.example.com/=ssh://forgejo@git.example.com:2222/"
  end

test "a repository on a host without a git route is warned about by host name" do
  write_file "farmy.yml", fixture("farmy/keys.yml") # the git route's host is github.com
  secrets_provider GIT_TOKEN: "ghp_9c1e5d7b2a"

  farmy "start", "notes" # notes: https://codeberg.org/acme/notes.git; starts shop first

  assert_success
  assert_stderr "codeberg.org"
  assert_running "notes"
end

test "with routes for two hosts each app container is given both rewrites" do
  write_file "farmy.yml", fixture("farmy/keys-two-hosts.yml") # github: https://github.com, codeberg: https://codeberg.org
  secrets_provider GITHUB_TOKEN: "ghp_9c1e5d7b2a", CODEBERG_TOKEN: "cb_4e8a1f"

  farmy "start", "notes"

  assert_env "notes", "DEV_GIT_ROUTES", /https:\/\/codeberg\.org=http:\/\/keys:9181\/codeberg\//
  assert_env "notes", "DEV_GIT_ROUTES", /https:\/\/github\.com=http:\/\/keys:9181\/github\//
  assert_env "shop", "DEV_GIT_ROUTES", /https:\/\/github\.com=http:\/\/keys:9181\/github\//
  assert_loaded_into "notes-keys", "GITHUB_TOKEN", "CODEBERG_TOKEN"
end

  test "keys --why runs the provider once and prints its stderr with every secret and unlocking value redacted" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml") # secrets.unlock: [INFISICAL_TOKEN], an anthropic route
    secrets_provider_chatty stderr: "token st.d41d8cd9 accepted; ANTHROPIC_API_KEY is sk-ant-7f3a9c; folder /farmy not found", ANTHROPIC_API_KEY: "sk-ant-7f3a9c"

    farmy "keys", "--why", stdin: "INFISICAL_TOKEN=st.d41d8cd9\n"

    assert_success
    assert_stdout "folder /farmy not found"
    assert_stdout "[redacted]"
    refute_stdout "st.d41d8cd9"
    refute_stdout "sk-ant-7f3a9c"
    refute_stderr "sk-ant-7f3a9c"
  end

  test "keys --why loads nothing into a broker" do
    write_file "farmy.yml", fixture("farmy/keys.yml")
    secrets_provider GIT_TOKEN: "frg_9c1e5d7b2a"
    farmy "start", "shop"
    secrets_provider_chatty stderr: "all good", GIT_TOKEN: "frg_new4e7b1c"

    farmy "keys", "--why"

    assert_success
    refute_given_on_stdin "shop-keys", "frg_new4e7b1c"
    refute_secret_anywhere "frg_new4e7b1c"
  end

  test "a multi-line SSH key from the unlock command reaches the broker's agent byte for byte, through the shim, farmy and the load" do
    shim "init"
    write_file "farmy.yml", "secrets:\n  provider: [providers/env]\n  unlock: [GIT_SSH_KEY]\n" + fixture("farmy/keys-ssh.yml").sub(/\A.*?keys:\n/m, "keys:\n")
    write_file "vault/GIT_SSH_KEY", fixture("keys/git_ed25519")
    unlock_command "cat \"vault/$1\""
    shim "start", "shop"
    assert_equal fixture("keys/git_ed25519").chomp, value_passed_to_farmy("GIT_SSH_KEY")

    farmy "start", "shop", stdin: stdin_passed_to_farmy
    start_broker routes: { "git" => "- ssh - GIT_SSH_KEY" }
    load_broker_raw stdin_loaded_into("shop-keys")

    assert_includes agent_identities, "farmy-test-key"
  end

  test "a route with encoding: base64 has its secret decoded before the broker is loaded" do
    write_file "farmy.yml", fixture("farmy/keys-ssh.yml").sub("    auth: ssh\n", "    auth: ssh\n    encoding: base64\n")
    secrets_provider_raw GIT_SSH_KEY: [fixture("keys/git_ed25519")].pack("m0")

    farmy "start", "shop"

    assert_success
    assert_equal fixture("keys/git_ed25519"), value_loaded_into("shop-keys", "GIT_SSH_KEY")
  end

  test "an SSH route whose secret is a base64-encoded key, without encoding: base64, is not loaded and farmy keys says it looks base64-encoded" do
    write_file "farmy.yml", fixture("farmy/keys-ssh.yml")
    secrets_provider_raw GIT_SSH_KEY: [fixture("keys/git_ed25519")].pack("m0")
    farmy "start", "shop"
    refute_loaded_into "shop-keys", "GIT_SSH_KEY"

    farmy "keys"

    assert_stdout(/^git\s.*rejected.*base64/)
    assert_stdout "encoding: base64"
  end

  test "farmy keys reads the brokers: after the keys container restarts, a route reads not loaded" do
    write_file "farmy.yml", fixture("farmy/keys.yml")
    secrets_provider GIT_TOKEN: "frg_9c1e5d7b2a"
    farmy "start", "shop"
    docker "restart", "shop-keys"

    farmy "keys"

    assert_stdout(/^git\s.*not loaded/)
    assert_stdout "farmy keys reload"
  end

  test "restart loads the secrets into the keys container it made anew" do
    write_file "farmy.yml", fixture("farmy/keys.yml")
    secrets_provider GIT_TOKEN: "frg_9c1e5d7b2a"
    farmy "start", "shop"

    farmy "restart", "shop"

    assert_success
    assert_loaded_since_start "shop-keys", "GIT_TOKEN"
    farmy "keys"
    assert_stdout(/^git\s+.*\bloaded\b/)
    refute_stdout(/^git\s.*not loaded/)
  end

  test "start loads the broker before the clone, so a clone over an SSH route succeeds" do
    write_file "farmy.yml", fixture("farmy/keys-ssh.yml")
    secrets_provider_raw GIT_SSH_KEY: fixture("keys/git_ed25519")

    farmy "start", "shop"

    assert_success
    assert_loaded_since_start "shop-keys", "GIT_SSH_KEY"
    refute_stderr "clone failed"
  end

  %w[restart rebuild].each do |command|
    test "#{command} makes the keys container anew and loads it before the clone" do
      write_file "farmy.yml", fixture("farmy/keys-ssh.yml")
      secrets_provider_raw GIT_SSH_KEY: fixture("keys/git_ed25519")
      farmy "start", "shop"

      farmy command, "shop"

      assert_success
      assert_loaded_since_start "shop-keys", "GIT_SSH_KEY"
      refute_stderr "clone failed"
    end
  end

  test "a git route's broker spec ends in public, an API route's does not" do
    write_file "farmy.yml", fixture("farmy/keys.yml") # git: https://github.com, git: true; anthropic: an API route
    secrets_provider GIT_TOKEN: "frg_9c1e5d7b2a"

    farmy "start", "shop"

    assert_env "shop-keys", "FARMY_ROUTE_GIT", "https://github.com basic x-access-token GIT_TOKEN public"
    assert_env "shop-keys", "FARMY_ROUTE_ANTHROPIC", "https://api.anthropic.com header x-api-key ANTHROPIC_API_KEY"
  end
end
