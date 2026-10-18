# The shim (`farmy` in the work folder) through the fake docker: the seam between it and the control image.
class ShimTest < AcceptanceTest
  def setup = workspace("workshop")

  test "init through the shim leaves the control container up, with a process that is not the farmy binary" do
    shim "init"

    assert_running "farmy"
    refute_process "farmy", "farmy"
  end

  test "the control container runs with Docker's CLI hints off" do
    shim "init"

    assert_env "farmy", "DOCKER_CLI_HINTS", "false"
  end

test "the control container gets the host's TZ, so the session's clock is local" do
  shim "init", env: { "TZ" => "Europe/Berlin" }

  assert_env "farmy", "TZ", "Europe/Berlin"
end

  test "local development init twice builds the control image once" do
    shim "init"

    shim "init"

    assert_builds "farmy:local", 1
  end

  test "local development init rebuilds the control image when its build inputs changed since it was built" do
    docker "build", "-q", "-t", "farmy:local", "--label", "farmy.hash=9b1c-of-an-older-dockerfile", "-", stdin: "FROM alpine:3.21\nCMD [\"farmy\", \"help\"]\n"

    shim "init"

    assert_builds "farmy:local", 2
    assert_running "farmy"
  end

  test "the control container is started on the farmy network, which the shim creates when it is missing" do
    shim "init"

    assert_network "farmy", "farmy"
  end

  test "a control container from before, on the default bridge, is attached to the farmy network" do
    shim "init"
    docker "network", "disconnect", "farmy", "farmy"

    shim "status"

    assert_network "farmy", "farmy"
  end

  test "on a Linux host the control container gets the socket docker context names, a rootless one included" do
    linux_host
    docker_context "unix:///run/user/1000/docker.sock"

    shim "init"

    assert_binds "farmy", "/run/user/1000/docker.sock", at: "/var/run/docker.sock"
  end

  test "a Docker context that is not a local socket is refused, saying farmy needs a local Docker" do
    docker_context "tcp://build.example.com:2376"

    shim "init"

    assert_exit 1
    assert_stderr "tcp://build.example.com:2376"
    assert_stderr "local"
    refute_container "farmy"
  end
end
