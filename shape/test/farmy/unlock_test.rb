# How the shim obtains the unlocking values before it hands start to the control container: the
# store on the PATH, an unlock command, else a prompt. Through the fake docker, what farmy received.
class UnlockTest < AcceptanceTest
  def setup = shim_workspace("workshop") # shop, notes, toolkit; the control container up

  test "the Keychain on the PATH yields an unlocking value under the prefixed name, and farmy receives it on stdin" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml") # secrets.unlock: [INFISICAL_TOKEN]
    keychain "farmy/INFISICAL_TOKEN" => "st.d41d8cd9"

    shim "start", "shop"

    assert_success
    assert_store_asked "find-generic-password -s farmy/INFISICAL_TOKEN -w"
    assert_passed_to_farmy "INFISICAL_TOKEN=st.d41d8cd9"
    refute_secret_anywhere "st.d41d8cd9"
  end

  test "the secret service on the PATH yields it under the attribute farmy with the prefixed name" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    secret_service "farmy farmy/INFISICAL_TOKEN" => "st.d41d8cd9"

    shim "start", "shop"

    assert_success
    assert_store_asked "lookup farmy farmy/INFISICAL_TOKEN"
    assert_passed_to_farmy "INFISICAL_TOKEN=st.d41d8cd9"
    refute_secret_anywhere "st.d41d8cd9"
  end

  test "FARMY_SECRET_PREFIX changes the name looked up in the Keychain" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    keychain "acme/INFISICAL_TOKEN" => "st.4a7e21", "farmy/INFISICAL_TOKEN" => "st.d41d8cd9"

    shim "start", "shop", env: { "FARMY_SECRET_PREFIX" => "acme/" }

    assert_store_asked "find-generic-password -s acme/INFISICAL_TOKEN -w"
    assert_passed_to_farmy "INFISICAL_TOKEN=st.4a7e21"
  end

  test "FARMY_SECRET_PREFIX changes the name looked up in the secret service" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    secret_service "farmy acme/INFISICAL_TOKEN" => "st.4a7e21", "farmy farmy/INFISICAL_TOKEN" => "st.d41d8cd9"

    shim "start", "shop", env: { "FARMY_SECRET_PREFIX" => "acme/" }

    assert_store_asked "lookup farmy acme/INFISICAL_TOKEN"
    assert_passed_to_farmy "INFISICAL_TOKEN=st.4a7e21"
  end

  test "an entry in the old Keychain form, service farmy and account NAME, is no longer found: one name only" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    keychain ["farmy", "INFISICAL_TOKEN"] => "st.d41d8cd9"

    shim "start", "shop"

    assert_store_asked "find-generic-password", times: 1
    refute_passed_to_farmy "INFISICAL_TOKEN"
  end

  test "an entry in the old secret service form, service farmy and account NAME, is no longer found: one name only" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    secret_service "service farmy account INFISICAL_TOKEN" => "st.d41d8cd9"

    shim "start", "shop"

    assert_store_asked "lookup", times: 1
    refute_passed_to_farmy "INFISICAL_TOKEN"
  end

  test "a locked Keychain is unlocked once with security unlock-keychain, then every value is read" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml").sub("unlock: [INFISICAL_TOKEN]", "unlock: [INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET]")
    keychain({ "farmy/INFISICAL_CLIENT_ID" => "5b0c7e1d-2f3a", "farmy/INFISICAL_CLIENT_SECRET" => "cs_9e2f4b7a1c" }, locked: true)

    shim "start", "shop"

    assert_success
    assert_store_asked "unlock-keychain", times: 1
    assert_passed_to_farmy "INFISICAL_CLIENT_ID=5b0c7e1d-2f3a"
    assert_passed_to_farmy "INFISICAL_CLIENT_SECRET=cs_9e2f4b7a1c"
  end

  test "a locked secret service is reported as locked, and the value is asked for instead of read" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    secret_service({ "farmy farmy/INFISICAL_TOKEN" => "st.d41d8cd9" }, locked: true)

    shim "start", "shop"

    assert_success
    assert_stderr(/locked/)
    refute_passed_to_farmy "INFISICAL_TOKEN"
    assert_ran_in "farmy", "start shop"
  end

  test "a name the store does not have is asked for on a terminal; without one it is left out and start goes on" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    keychain({})

    shim "start", "shop"

    assert_success
    assert_stderr "INFISICAL_TOKEN"
    refute_passed_to_farmy "INFISICAL_TOKEN"
    assert_ran_in "farmy", "start shop"
  end

  test "FARMY_UNLOCK_COMMAND is a shell line run in the containers folder with the name as $1" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    write_file "my vault/INFISICAL_TOKEN", "st.d41d8cd9\n"
    unlock_command 'cat "my vault/$1"'

    shim "start", "shop"

    assert_success
    assert_passed_to_farmy "INFISICAL_TOKEN=st.d41d8cd9"
  end

  test "an unlock command that does not mention $1 gets the name as its last argument" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    write_executable "bin/unlock", "#!/bin/sh\ncase \"$1\" in INFISICAL_TOKEN) echo st.d41d8cd9 ;; *) exit 1 ;; esac\n"
    unlock_command "bin/unlock"

    shim "start", "shop"

    assert_passed_to_farmy "INFISICAL_TOKEN=st.d41d8cd9"
  end

  test "the unlock command is the source when it is set, even with a store on the PATH" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    keychain "farmy/INFISICAL_TOKEN" => "st.from-the-keychain"
    write_executable "bin/unlock", "#!/bin/sh\necho st.from-the-command\n"
    unlock_command "bin/unlock"

    shim "start", "shop"

    assert_passed_to_farmy "INFISICAL_TOKEN=st.from-the-command"
    assert_store_asked "find-generic-password", times: 0
  end

  test "FARMY_SECRET_PREFIX in .env is used when the environment has none" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    settings FARMY_SECRET_PREFIX: "acme/"
    keychain "acme/INFISICAL_TOKEN" => "st.4a7e21"

    shim "start", "shop"

    assert_store_asked "find-generic-password -s acme/INFISICAL_TOKEN -w"
    assert_passed_to_farmy "INFISICAL_TOKEN=st.4a7e21"
  end

  test "the shim obtains the unlocking values for keys --why" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    keychain "farmy/INFISICAL_TOKEN" => "st.d41d8cd9"

    shim "keys", "--why"

    assert_passed_to_farmy "INFISICAL_TOKEN=st.d41d8cd9"
  end

  test "FARMY_UNLOCK_COMMAND in .env is used when the environment has none" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml")
    write_executable "bin/unlock", "#!/bin/sh\necho st.from-env-file\n"
    settings FARMY_UNLOCK_COMMAND: "bin/unlock"

    shim "start", "shop"

    assert_passed_to_farmy "INFISICAL_TOKEN=st.from-env-file"
  end

  test "a secret service that cannot be reached is named once, asked nothing more, and every value is asked for instead" do
    write_file "farmy.yml", fixture("farmy/keys-unlock.yml").sub("unlock: [INFISICAL_TOKEN]", "unlock: [INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET]")
    secret_service({}, unreachable: true) # every lookup: "Cannot autolaunch D-Bus without X11 $DISPLAY", exit 1

    shim "start", "shop"

    assert_success
    assert_store_asked "lookup", times: 1
    assert_stderr_once "Cannot autolaunch D-Bus"
    assert_stderr "INFISICAL_CLIENT_SECRET" # no terminal: left out, named
  end

  # Every command that loads a broker or runs the provider gets its values the same way: the holder, then the store, then a prompt.
  { "start" => %w[start shop], "restart" => %w[restart shop], "rebuild" => %w[rebuild shop], "keys reload" => %w[keys reload shop],
    "keys --why" => %w[keys --why], "factory start" => ["factory", "start", "shop", "--task", "Make the check pass."] }.each do |label, command|
    test "farmy #{label} with nothing held reads the Keychain under the prefix from .env and asks for nothing" do
      write_file "farmy.yml", fixture("farmy/keys-unlock.yml") # secrets.unlock: [INFISICAL_TOKEN]; the control container holds nothing yet
      settings FARMY_SECRET_PREFIX: "acme/"
      keychain "acme/INFISICAL_TOKEN" => "st.4a7e21"

      shim(*command)

      assert_store_asked "find-generic-password -s acme/INFISICAL_TOKEN -w"
      assert_passed_to_farmy "INFISICAL_TOKEN=st.4a7e21"
      refute_stderr "INFISICAL_TOKEN"
    end
  end
end
