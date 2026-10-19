# Factory logins: an agent's subscription login of its own for unattended runs, never the interactive shared
# login. farmy factory login <service> <agent> makes it in the volume farmy-factory-login-<agent> by running the
# entry's factory_login command; mode: login mounts it in that agent's factory containers. login_factory sets up
# shop (its check passes once src/app.txt says fixed) with profile work running codex in mode: login.
class FactoryLoginTest < AcceptanceTest
  test "farmy factory login runs the agent's factory_login command in the service image, as dev, with the agent's own login volume, made the dev user's, at its login path" do
    login_factory

    factory_login "codex"

    assert_success
    assert_login_ran "codex", at: "/home/dev/.codex", line: "codex login --device-auth"
    assert_volume_owner "farmy-factory-login-codex", 1001
  end

  test "the login container goes out the way the service's git helpers do" do
    login_factory

    factory_login "codex"

    assert_login_goes_out_like_the_git_helpers
  end

  test "a login that fails on a new volume removes that volume and reports the command's exit code" do
    login_factory
    login_fails

    factory_login "codex"

    assert_exit 1
    assert_stderr "codex login --device-auth"
    assert_stderr "exit 1"
    refute_volume "farmy-factory-login-codex"
  end

  test "farmy factory login for an agent without factory_login is refused, naming factory_login" do
    login_factory agent: "mytool", extra_config: mytool_agent

    factory_login "mytool"

    assert_exit 1
    assert_stderr "factory_login"
    assert_empty login_containers
  end

  test "farmy factory login for an agent the service's image does not carry is refused, naming the agent" do
    profiled_factory # claude in both profiles: shop's image carries no codex

    factory_login "codex"

    assert_exit 1
    assert_stderr "codex"
    assert_empty login_containers
  end

  test "a factory agent in login mode mounts its agent's login volume, writable, at the login path, and gets no token and no farmy-shared" do
    login_factory
    logged_in "codex"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start profile: "work"

    assert_success
    assert_run_mount "agent", "farmy-factory-login-codex", at: "/home/dev/.codex", readonly: false
    refute_run_env "agent", "CODEX_API_KEY"
    refute_run_volume "agent", "farmy-shared"
  end

  test "login mode before farmy factory login is refused, naming the command that creates the login, and no agent runs" do
    login_factory

    factory_start profile: "work"

    assert_exit 1
    assert_stderr "farmy factory login shop codex"
    assert_agent_count 0
  end

  test "login mode for an agent without factory_login is refused, naming the agent and factory_login" do
    login_factory agent: "mytool", extra_config: mytool_agent

    factory_start profile: "work"

    assert_exit 1
    assert_stderr "mytool"
    assert_stderr "factory_login"
  end

  test "an agent of your own may declare factory_login, and its runs in login mode mount that login" do
    login_factory agent: "mytool", extra_config: mytool_agent(factory_login: "{path: .mytool, create: mytool auth --device}")
    logged_in "mytool"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start profile: "work"

    assert_success
    assert_login_ran "mytool", at: "/home/dev/.mytool", line: "mytool auth --device"
    assert_run_mount "agent", "farmy-factory-login-mytool", at: "/home/dev/.mytool", readonly: false
  end

  test "a factory_login path outside the home folder is refused by name" do
    login_factory agent: "mytool", extra_config: mytool_agent
    give_mytool_factory_login "{path: ../../etc/mytool, create: mytool auth --device}"

    factory_login "mytool"

    assert_exit 1
    assert_stderr "factory_login"
    assert_empty login_containers
  end

  test "two runs on the same factory login take turns: the second agent waits in login_wait until the first agent ends, though a slot is free" do
    login_factory
    logged_in "codex"
    agent_plays({ barrier: "first-login", writes: { "src/app.txt" => "fixed\n" } }, { barrier: "second-login", writes: { "src/app.txt" => "fixed\n" } })

    simultaneously ["factory", "start", "shop", "--profile", "work", "--task", "First change"],
                   ["factory", "start", "shop", "--profile", "work", "--task", "Second change"]

    assert_simultaneous_success
    wait_agent_barrier "first-login"
    wait_for_factory_phase "login_wait"
    assert_agent_count 1
    release_agent_barrier "first-login"
    wait_agent_barrier "second-login"
    assert_agent_count 2
  end

  test "farmy destroy leaves the factory login volumes" do
    login_factory
    logged_in "codex"

    farmy "destroy", "shop", stdin: "y\n"

    assert_success
    assert_volume "farmy-factory-login-codex"
  end
end
