class StartTest < AcceptanceTest
  def setup = workspace("workshop") # shop (ruby image, postgres + redis in its compose:, ports 3100:3000), notes (start_after shop, 3200:5173 3201:24678), toolkit

  test "starting shop publishes the host port of its first ports: pair on the container port" do
    farmy "start", "shop"

    assert_success
    assert_running "shop"
    assert_publishes "shop", "3100:3000"
  end

  test "a service with several ports: pairs publishes each of them" do
    farmy "start", "notes" # ports: ["3200:5173", "3201:24678"]

    assert_success
    assert_publishes "notes", "3200:5173", "3201:24678"
  end

  test "every container farmy starts has an init process" do
    farmy "start", "shop"

    assert_init "shop", "shop-pg", "shop-redis", "shop-keys", "farmy-knowledge"
  end

test "every bind mount of a container farmy starts is inside the containers folder, never farmy's own files" do
  farmy "start", "shop" # the knowledge container too; farmy's README and docs live in its image, not on the host

  assert_running "farmy-knowledge"
  assert_binds_within_workspace
end

  test "the checkout lives on a volume named after the service" do
    farmy "start", "shop"

    assert_mounted "shop", "shop-src"
  end

  test "a services/<name>.env file reaches that app container" do
    write_file "services/shop.env", "RAILS_MAX_THREADS=5\n" # settings: the agent inside can read it, so no secret here

    farmy "start", "shop"

    assert_env "shop", "RAILS_MAX_THREADS", "5"
  end

  test "${url:shop} in a manifest becomes shop's address on the host" do
    farmy "start", "notes" # env: VITE_API_URL: ${url:shop}

    assert_env "notes", "VITE_API_URL", "http://localhost:3100"
  end

  test "${port:shop} in a manifest becomes shop's first host port" do
    farmy "start", "notes" # env: API_PORT: ${port:shop}

    assert_env "notes", "API_PORT", "3100"
  end

  test "starting notes starts shop first because notes asks for it" do
    farmy "start", "notes"

    assert_running "shop", "notes"
    assert_started_before "shop", "notes"
  end

  test "the shared knowledge container farmy-knowledge starts with the first service" do
    farmy "start", "shop"

    assert_running "farmy-knowledge"
  end

  test "starting a service that is already running leaves it running and says so" do
    farmy "start", "shop"

    farmy "start", "shop"

    assert_success
    assert_stdout "already running"
    assert_running "shop"
  end

  test "starting without Docker running is refused" do
    docker_is_down

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "Docker"
  end

  test "starting without .env and with no Git identity anywhere is refused, init is pointed at, and no .env is written" do
    delete_file ".env" # and the suite gives farmy no global git configuration and no GIT_USER_NAME

    farmy "start", "shop"

    assert_exit 1
    assert_stderr ".env"
    assert_stderr "farmy init"
    refute_container "shop"
    refute_file ".env"
  end

  test "starting without .env takes the Git identity from the environment, writes .env with it, and starts" do
    delete_file ".env"

    farmy "start", "shop", env: { "GIT_USER_NAME" => "Dana Brooks", "GIT_USER_EMAIL" => "dana@example.com" }

    assert_success
    assert_running "shop"
    assert_file ".env", includes: "GIT_USER_NAME=Dana Brooks"
    assert_file ".env", includes: "GIT_USER_EMAIL=dana@example.com"
  end

  test "starting with an .env that lacks the Git identity is refused by key" do
    write_file ".env", "LAN_HOST=workshop.local\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "GIT_USER_NAME"
    refute_container "shop"
  end

  test "starting without a git route works and says that only public repositories clone" do
    farmy "start", "shop" # no farmy.yml: no routes, no provider

    assert_success
    assert_stderr "public repositories"
    assert_stderr "github.com"
    assert_running "shop"
  end

  test "start without a service name is a mistake in the command line" do
    farmy "start"

    assert_exit 2
    assert_stderr "start"
  end
  test "a service clone failure ends start with exit 1 and its reason while keeping the app available" do
    clone_fails "shop", "fatal: unable to access 'https://github.com/acme/shop.git/': Could not resolve host: github.com"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "shop"
    assert_stderr "Could not resolve host: github.com"
    refute_stdout "there"
    assert_running "shop"
  end

  test "a stale clone marker from an earlier attempt is removed before the containers come up, and start goes on" do
    volume_file "shop-src", ".farmy-clone", "failed\nfatal: repository 'https://github.com/acme/old.git/' not found\n"

    farmy "start", "shop"

    assert_success
    refute_stderr "acme/old.git"
    assert_running "shop"
  end

  test "a failed SSH clone names ssh's authentication line, not only git's last lines" do
    clone_fails "shop", "Cloning into '/workspace'...\ngit@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\nConnection closed by UNKNOWN port 65535"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "Permission denied (publickey)"
  end

  test "a failed clone names the first line that names the cause and none of git's closing advice" do
    clone_fails "shop", "Error connecting to agent: Connection refused\ngit@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists."

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "Error connecting to agent: Connection refused"
    refute_stderr "Please make sure"
    refute_stderr "and the repository exists"
  end

  test "with FARMY_TTY=1 a build's output collapses: no build line stays on the screen" do
    farmy "start", "shop", env: { "FARMY_TTY" => "1" }

    assert_success
    refute_on_screen "RUN apt-get update"
    refute_on_screen "Reading package lists"
  end

  test "start leaves the checkout volume for compose to create: compose warns about no volume it did not make" do
    farmy "start", "shop"

    assert_success
    refute_stderr "was not created by Docker Compose"
  end

  test "a clone that fails on ownership names git's dubious ownership line" do
    clone_fails "shop", "Cloning into '/workspace'...\nfatal: detected dubious ownership in repository at '/workspace/.git'\nTo add an exception for this directory, call:\n\n\tgit config --global --add safe.directory /workspace\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists."

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "detected dubious ownership in repository at '/workspace/.git'"
    refute_stderr "and the repository exists"
  end

  test "a clone that fails on a name it cannot resolve names getaddrinfo's line" do
    clone_fails "shop", "Cloning into '/workspace'...\nnc: getaddrinfo for host \"farmy-egress\" port 1055: Name or service not known\nkex_exchange_identification: Connection closed by remote host\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists."

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "getaddrinfo for host \"farmy-egress\" port 1055: Name or service not known"
  end
end
