# The control container holds the values the host gave, in a process's memory, for its lifetime: later
# provider runs and broker reloads take them from there, the shim asks the host only for what is not held,
# and farmy lock clears them.
class HoldTest < AcceptanceTest
  def setup = workspace("workshop") # shop on github.com; no farmy.yml

  test "after a start with an unlocking value, keys reload without one gives the provider the value the control container holds" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml") # secrets.unlock: [INFISICAL_TOKEN], an anthropic route
    secrets_provider ANTHROPIC_API_KEY: "sk-ant-7f3a9c"
    farmy "start", "shop", stdin: "INFISICAL_TOKEN=st.d41d8cd9\n"
    delete_file "provider.log"

    farmy "keys", "reload", "shop"

    assert_success
    assert_file "provider.log", includes: "env: INFISICAL_TOKEN=st.d41d8cd9"
  end

  test "the holder's socket is 0600 even when farmy runs with umask 000" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    secrets_provider ANTHROPIC_API_KEY: "sk-ant-7f3a9c"

    farmy_under_umask 0o000, "start", "shop", stdin: "INFISICAL_TOKEN=st.d41d8cd9\n"

    assert_success
    assert_holder_socket_mode 0o600
  end

  test "farmy unlock-names --missing lists only the names the holder does not have" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    secrets_provider ANTHROPIC_API_KEY: "sk-ant-7f3a9c"
    farmy "unlock-names", "--missing"
    assert_stdout_is "INFISICAL_TOKEN\n"
    farmy "start", "shop", stdin: "INFISICAL_TOKEN=st.d41d8cd9\n"

    farmy "unlock-names", "--missing"

    assert_stdout_is ""
  end

  test "farmy lock clears the holder: the next reload without a value reads locked" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    secrets_provider ANTHROPIC_API_KEY: "sk-ant-7f3a9c"
    farmy "start", "shop", stdin: "INFISICAL_TOKEN=st.d41d8cd9\n"

    farmy "lock"
    assert_success
    farmy "keys", "reload", "shop"
    farmy "keys"

    assert_stdout(/^anthropic\s.*\blocked\b/)
  end

  test "the held value is in no file, no docker command line and no output" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    secrets_provider ANTHROPIC_API_KEY: "sk-ant-7f3a9c"
    farmy "start", "shop", stdin: "INFISICAL_TOKEN=st.d41d8cd9\n"

    farmy "keys", "reload", "shop"

    refute_secret_anywhere "st.d41d8cd9"
  end

  test "the shim asks the store only for the names the control container does not hold, and again after farmy lock" do
    shim "init"
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    keychain "farmy/INFISICAL_TOKEN" => "st.d41d8cd9"
    shim "start", "shop"
    shim "restart", "shop"
    assert_store_asked "find-generic-password", times: 1

    shim "lock"
    shim "restart", "shop"

    assert_store_asked "find-generic-password", times: 2
  end
end
