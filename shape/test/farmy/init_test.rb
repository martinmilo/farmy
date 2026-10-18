class InitTest < AcceptanceTest
  # Each test starts in an empty folder: the containers folder on a machine that is new to farmy.

  test "init writes .env with the name and email the host's Git is configured with" do
    host_git_identity "Ines Hartmann", "ines@hartmann.dev"

    farmy "init"

    assert_success
    assert_file ".env", includes: "GIT_USER_NAME=Ines Hartmann"
    assert_file ".env", includes: "GIT_USER_EMAIL=ines@hartmann.dev"
  end

  test "init leaves an existing .env as it is" do
    write_file ".env", "GIT_USER_NAME=Ines Hartmann\nGIT_USER_EMAIL=ines@hartmann.dev\nLAN_HOST=workshop.local\n"

    farmy "init"

    assert_success
    assert_unchanged ".env"
  end

  test "init without Docker running stops at Docker and writes nothing" do
    host_git_identity "Ines Hartmann", "ines@hartmann.dev"
    docker_is_down

    farmy "init"

    assert_exit 1
    assert_stderr "Docker"
    assert_nothing_written
  end

  test "init in a folder without services says so and names the README section" do
    host_git_identity "Ines Hartmann", "ines@hartmann.dev"

    farmy "init"

    assert_success
    assert_stdout "no services defined yet"
    assert_stdout "Adding a service"
  end

  test "init without a git route says that only public repositories will clone" do
    host_git_identity "Ines Hartmann", "ines@hartmann.dev"

    farmy "init"

    assert_success
    assert_stderr "public repositories"
  end
  test "init takes the identity from GIT_USER_NAME and GIT_USER_EMAIL in its environment when the host has no git configuration" do
    host_git_identity "", "" # the control container never sees the host's git config; the shim passes it in the environment

    farmy "init", env: { "GIT_USER_NAME" => "Ines Hartmann", "GIT_USER_EMAIL" => "ines@hartmann.dev" }

    assert_success
    assert_file ".env", includes: "GIT_USER_NAME=Ines Hartmann"
    assert_file ".env", includes: "GIT_USER_EMAIL=ines@hartmann.dev"
  end

  test "init without a terminal turns no agent on, writes no farmy.yml, and says how to turn one on" do
    farmy "init"

    assert_success
    refute_file "farmy.yml"
    assert_stdout "agents:"
    assert_stdout "farmy.yml"
  end
end
