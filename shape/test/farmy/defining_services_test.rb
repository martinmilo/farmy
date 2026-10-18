class DefiningServicesTest < AcceptanceTest
  def setup = settings # a folder with .env and nothing else: no services/

  test "status in a folder without services says that none is defined yet and where to add one" do
    farmy "status"

    assert_success
    assert_stdout "no services defined yet"
    assert_stdout "Adding a service"
  end

  test "starting a service when none is defined says so" do
    farmy "start", "shop"

    assert_exit 2
    assert_stderr "no services are defined yet"
    assert_stderr "Adding a service"
  end

  test "a service without a definition is unknown and the defined ones are named" do
    workspace "workshop"

    farmy "start", "crm"

    assert_exit 2
    assert_stderr "unknown service 'crm'"
    assert_stderr(/notes.*shop.*toolkit/)
  end

  test "status shows a service that was never started as stopped" do
    workspace "workshop"

    farmy "status"

    assert_stdout(/^shop\s+stopped\b/)
  end

  test "a definition with neither image nor dockerfile is refused by both names" do
    workspace "workshop"
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\n" # the repository may well have a Dockerfile; it is not a development image

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "services/shop.yml"
    assert_stderr "image:"
    assert_stderr "dockerfile:"
    refute_container "shop"
  end

  test "repo: none starts a workbench: an empty workspace volume and no clone" do
    workspace "workshop"
    write_file "services/toolkit.yml", "repo: none\nimage: debian:bookworm-slim\n"

    farmy "start", "toolkit"

    assert_success
    assert_running "toolkit"
    assert_mounted "toolkit", "toolkit-src", at: "/workspace"
    refute_env "toolkit", "REPO"
  end

  test "status shows a workbench's repository as none" do
    workspace "workshop"
    write_file "services/toolkit.yml", "repo: none\nimage: debian:bookworm-slim\n"

    farmy "status"

    assert_stdout(/^toolkit\s.*\bnone\b/)
  end
end
