class CommandsTest < AcceptanceTest
  def setup = workspace("workshop") # shop's commands: setup bin/setup --skip-server, start bin/rails server -b 0.0.0.0, test bin/rails test

  test "the setup command runs in the checkout after the clone, as the dev user" do
    farmy "start", "shop"

    assert_ran_in "shop", "bin/setup", in: "/workspace", as: "dev"
  end

  test "a service with a workdir runs its commands there" do
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nworkdir: backend\ncommands:\n  setup: bin/setup\n"

    farmy "start", "shop"

    assert_ran_in "shop", "bin/setup", in: "/workspace/backend"
  end

  test "run with a command name runs that command of the service" do
    farmy "start", "shop"

    farmy "run", "shop", "test"

    assert_success
    assert_ran_in "shop", "bin/rails test"
  end

  test "run with words that are no command name runs them as they are" do
    farmy "start", "shop"

    farmy "run", "shop", "ls", "-la"

    assert_success
    assert_ran_in "shop", "ls -la"
  end

  test "a setup that does not finish within setup_timeout is stopped, reported, and start exits 1 with the containers up" do
    write_file "farmy.yml", "setup_timeout: 2s\n"
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\ncommands:\n  setup: sleep 60\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "setup"
    assert_stderr "2s"
    assert_running "shop"
  end

  test "a definition without commands starts with no setup" do
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\n"

    farmy "start", "shop"

    assert_success
    refute_ran_in "shop", "bin/setup"
  end

  test "run gives the command GIT_PAGER=cat, so git does not page" do
    farmy "start", "shop"

    farmy "run", "shop", "git", "log"

    assert_success
    assert_exec_env "shop", "git log", "GIT_PAGER", "cat"
  end
end
