# What a fake Docker cannot show. These run against the real Docker and the real shim; they are skipped
# wherever `docker info` is the fake's, and run by hand on a machine with Docker: JOBS=1 bin/verify -n /Integration/
class IntegrationTest < AcceptanceTest
  def setup
    require_real_docker
    workspace "workshop"
  end

  test "a real restricted container curls an allowed registry and is denied example.com with a container log" do
    egress_apps
    real_shim "start", "shop"
    assert_success

    real_shim "run", "shop", "curl", "--fail", "--max-time", "20", "https://registry.npmjs.org/"
    assert_success
    real_shim "run", "shop", "curl", "--fail", "--max-time", "10", "https://example.com/"
    assert_failure
    assert_stderr(/403|denied/i)
    real_shim "egress", "log", "shop"
    assert_success
    assert_stdout "example.com"
    assert_stdout "shop"
  end

  test "farmy init leaves the control container running" do
    real_shim "init"

    assert_success
    assert_includes real_docker("inspect", "-f", "{{.State.Status}}", "farmy"), "running"
    refute_includes real_docker("logs", "farmy"), "unknown command"
  end

  test "a secret loaded into the broker is not in its Docker configuration" do
    write_file "farmy.yml", fixture("farmy/keys.yml")
    secrets_provider GIT_TOKEN: "frg_9c1e5d7b2a"

    real_shim "start", "shop"

    assert_success
    refute_includes real_docker("inspect", "shop-keys"), "frg_9c1e5d7b2a"
  end

  test "the toolbox builds on a Debian slim image, the supported path, and the agent CLI is inside" do
    write_file "farmy.yml", "agents:\n  claude: {}\n"
    write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\n"

    real_shim "start", "shop"

    assert_success
    assert_includes real_docker("exec", "-u", "dev", "shop", "sh", "-lc", "command -v claude && git --version"), "claude"
  end

  test "an agent of your own has its login path linked into farmy-shared in the real container, like a shipped one" do
    write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\n"
    write_file "farmy.yml", "agents:\n  mytool:\n    install: ~\n    login: .mytool\n    headless_login: mytool login --device\n"

    real_shim "start", "shop"

    assert_success
    assert_equal "/home/dev/.farmy-shared/mytool/.mytool", real_docker("exec", "shop", "readlink", "-f", "/home/dev/.mytool").strip
  end

  test "a setup that runs past the limit is stopped on a real Debian image" do
    write_file "farmy.yml", "setup_timeout: 3s\n"
    write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\ncommands:\n  setup: sleep 60\n"

    real_shim "start", "shop"

    assert_exit 1
    assert_stderr "setup"
    assert_includes real_docker("inspect", "-f", "{{.State.Status}}", "shop"), "running"
  end

  test "inside the container ~/.claude is on farmy-shared and ~/.claude/projects on the service's own volume" do
    write_file "farmy.yml", "agents:\n  claude: {}\n"
    write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\n"
    real_shim "start", "shop"
    assert_success

    out = real_docker "exec", "-u", "dev", "shop", "sh", "-lc", "readlink -f ~/.claude; readlink -f ~/.claude/projects"

    assert_includes out, "/home/dev/.farmy-shared/claude"
    assert_includes out, "/home/dev/.farmy-service/claude/projects"
  end

  test "the keys broker of a service without routes stays up, with its socket, as uid 1001" do
    write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\n"
    real_shim "start", "shop"
    assert_success
    sleep 3

    assert_equal "running 0", real_docker("inspect", "-f", "{{.State.Status}} {{.RestartCount}}", "shop-keys").strip
    assert_equal "1001", real_docker("exec", "shop-keys", "sh", "-c", "test -S /run/farmy-keys.sock && id -u").strip
  end

  test "the keys broker of a service with routes stays up, with its socket, as uid 1001" do
    write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\n"
    write_file "farmy.yml", fixture("farmy/keys.yml")
    secrets_provider GIT_TOKEN: "ghp_9c1e5d7b2a", ANTHROPIC_API_KEY: "sk-ant-7f3a9c"
    real_shim "start", "shop"
    assert_success
    sleep 3

    assert_equal "running 0", real_docker("inspect", "-f", "{{.State.Status}} {{.RestartCount}}", "shop-keys").strip
    assert_equal "1001", real_docker("exec", "shop-keys", "sh", "-c", "test -S /run/farmy-keys.sock && id -u").strip
  end

test "the egress node runs and its proxy port answers from another farmy container" do
  write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\n"
  write_file "farmy.yml", "egress:\n  join_timeout: 5s\n"

  real_shim "start", "shop"

  assert_success
  assert_includes real_docker("inspect", "-f", "{{.State.Status}}", "farmy-egress"), "running"
  assert_equal "open", real_docker("exec", "shop", "sh", "-c", "nc -z farmy-egress 1055 && echo open").strip
end

test "git in the app container reaches SSH hosts through the proxy: core.sshCommand uses nc -X 5" do
  write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\n"
  write_file "farmy.yml", "egress:\n  join_timeout: 5s\n"
  real_shim "start", "shop"
  assert_success

  assert_includes real_docker("exec", "-u", "dev", "shop", "git", "config", "core.sshCommand"), "nc -X 5 -x farmy-egress:1055"
end

  test "the egress node stays up while unregistered: no restart within 40 seconds" do
    write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\n"
    write_file "farmy.yml", "egress:\n  join_timeout: 5s\n"
    real_shim "start", "shop"
    assert_success
    sleep 40

    assert_equal "0 true", real_docker("inspect", "-f", "{{.RestartCount}} {{.State.Running}}", "farmy-egress").strip
  end

  test "the control container resolves the egress node by name" do
    write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\n"
    write_file "farmy.yml", "egress:\n  join_timeout: 5s\n"
    real_shim "start", "shop"

    refute_empty real_docker("exec", "farmy", "getent", "hosts", "farmy-egress").strip
  end

  test "the app image has an ssh client for git" do
    write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\n"
    real_shim "start", "shop"
    assert_success

    assert_includes real_docker("exec", "-u", "dev", "shop", "sh", "-c", "command -v ssh"), "/ssh"
  end

  test "the egress node runs in kernel mode with a tailscale0 interface" do
    write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\n"
    write_file "farmy.yml", "egress:\n  join_timeout: 5s\n"
    real_shim "start", "shop"

    assert_includes real_docker("exec", "farmy-egress", "ip", "link", "show", "tailscale0"), "tailscale0"
  end

  test "the entrypoint turns DEV_GIT_SSH_ROUTES into git's insteadOf rule" do
    write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\nenv:\n  DEV_GIT_SSH_ROUTES: https://git.example.com/=ssh://forgejo@git.example.com:2222/\n"
    real_shim "start", "shop"
    assert_success

    assert_includes real_docker("exec", "-u", "dev", "shop", "git", "config", "--system", "--get", "url.ssh://forgejo@git.example.com:2222/.insteadof"), "https://git.example.com/"
  end

  test "inside the container ~/.claude.json is a file on farmy-shared and ~/.claude a folder" do
    write_file "farmy.yml", "agents:\n  claude: {}\n"
    write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\n"
    real_shim "start", "shop"
    assert_success

    out = real_docker "exec", "-u", "dev", "shop", "sh", "-c", "test -f \"$(readlink -f ~/.claude.json)\" && echo file; test -d \"$(readlink -f ~/.claude)\" && echo folder"

    assert_equal "file\nfolder", out.strip
  end

  test "the control image has tzdata: a zone in TZ gives a local date" do
    real_shim "status"

    refute_equal "UTC", real_docker("exec", "-e", "TZ=America/Denver", "farmy", "date", "+%Z").strip
  end

  test "the toolbox builds on an Alpine image (accepted, best effort)" do
    write_file "services/shop.yml", "repo: none\nimage: alpine:3.21\n"

    real_shim "start", "shop"

    assert_success
  end

  test "a request from one service reaches another through ${url:x}" do
    write_file "services/shop.yml", "repo: none\nimage: python:3.12-slim\ncommands:\n  start: python3 -m http.server 3000 --directory /workspace\n"
    write_file "services/notes.yml", "repo: none\nimage: debian:bookworm-slim\nstart_after: [shop]\nenv:\n  HUB_URL: ${url:shop}\n"
    real_shim "start", "notes"
    assert_success
    real_docker "exec", "-d", "-u", "dev", "shop", "sh", "-lc", "cd /workspace && python3 -m http.server 3000"
    sleep 2

    out = real_docker "exec", "-u", "dev", "notes", "sh", "-lc", "curl -fsS -o /dev/null -w '%{http_code}' \"$HUB_URL/\""

    assert_includes out, "200"
  end

  test "the control image has the infisical CLI" do
    real_shim "status"

    assert_success
    assert_includes real_docker("exec", "farmy", "sh", "-lc", "command -v infisical && infisical --version"), "infisical"
  end

  test "the control image has docker buildx" do
    real_shim "status"

    assert_includes real_docker("exec", "farmy", "docker", "buildx", "version"), "buildx"
  end

  test "the session starts, detaches and reattaches" do
    real_shim "session", "--background"

    assert_success
    assert_includes real_docker("exec", "farmy", "tmux", "list-sessions"), "farmy"
  end

  test "bare farmy without a terminal prints the usage instead of attaching" do
    real_shim

    assert_success
    assert_stdout(/^\s+start\b/)
  end
  test "a stranger's start: the token route clones from an http git host through the broker, the values come from the secret service, Claude is in api-key mode, nothing of egress runs, and every file farmy wrote is the user's" do
    skip "the stranger's host is Linux: here the Keychain (security) would be asked before the secret service" if system("command -v security >/dev/null 2>&1")
    delete_file "services/shop.yml"
    real_shim "add", "http://githost:3000/acme/shop.git", "--image", "debian:bookworm-slim"
    assert_owned_by_me "services/shop.yml"
    define_on_http_git_host "shop", "acme/shop" # http://githost:3000/acme/shop.git, one commit "Seed the shop", the Authorization of each request logged
    write_file "farmy.yml", fixture("farmy/stranger.yml").sub("upstream: https://github.com", "upstream: http://githost:3000") # no provider
    secret_service "farmy farmy/GITHUB_TOKEN" => "ghp_7Hq2xV9c", "farmy farmy/ANTHROPIC_API_KEY" => "sk-ant-api03-4f9e"

    real_shim "start", "shop"

    assert_success
    assert_includes real_docker("exec", "-u", "dev", "shop", "git", "-C", "/workspace", "log", "--oneline"), "Seed the shop"
    assert_includes real_docker("exec", "shop-githost", "cat", "/tmp/auth.log"), "Basic eC1hY2Nlc3MtdG9rZW46Z2hwXzdIcTJ4Vjlj" # x-access-token:ghp_7Hq2xV9c
    assert_includes real_docker("exec", "shop", "printenv", "ANTHROPIC_API_KEY"), "via-farmy-keys"
    refute_includes real_docker("inspect", "shop", "shop-keys"), "ghp_7Hq2xV9c"
    refute_includes real_docker("inspect", "-f", "{{.Config.Env}}", "shop"), "HTTP_PROXY"
    assert_owned_by_me
  end

  test "with shared_logins: false ~/.claude is on the service's own volume, not farmy-shared" do
    write_file "farmy.yml", "agents:\n  claude: {}\n"
    write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\nshared_logins: false\n"
    real_shim "start", "shop"
    assert_success

    assert_equal "/home/dev/.farmy-service/logins/claude/.claude", real_docker("exec", "-u", "dev", "shop", "readlink", "-f", "/home/dev/.claude").strip
  end

  test "a factory run on a real Docker: an agent of your own fixes a file, the gate passes, the run branch has the commit" do
    write_file "services/shop.yml", fixture("definitions/factory-workbench.yml") # a workbench whose setup makes a repository with src/app.txt "broken"
    write_file "farmy.yml", fixture("farmy/factory-agent.yml")                  # fixer: headless "sh -c 'echo fixed > src/app.txt'", its token from FIXER_TOKEN
    real_shim "start", "shop", stdin: "FIXER_TOKEN=fx_4e7b1c\n"
    assert_success

    real_shim "factory", "start", "shop", "--task", "Fix src/app.txt.", "--wait"

    assert_success
    id = run_id
    assert_includes real_docker("run", "--rm", "-v", "shop-run-#{id}:/w", "--entrypoint", "git", "farmy/shop:dev", "-C", "/w", "log", "--format=%s", "-1", "farmy/shop/#{id}"), "farmy: iteration 1"
  end

  # Record 2026-10-29-1215: on Linux what farmy writes is the user's from the moment it is written, a session included.
  # As a plain user: the test's own when it is not root, else uid 4242 with the Docker socket's group.

  test "a first bare farmy through the real shim makes the default home the invoking user's while its session is still attached" do
    on_a_fresh_machine

    real_session_attached do
      assert_owned_by_the_user "~/.config/farmy", "~/.config/farmy/farmy.yml", "~/.config/farmy/services",
                               "~/.config/farmy/.gitignore", "~/.local/state/farmy/.work",
                               "~/.local/state/farmy/.work/config-git-declined"
    end
  end

  test "farmy init through the real shim writes .env in the default home as the invoking user's" do
    on_a_fresh_machine
    host_git_identity "Dana Brooks", "dana@example.com"

    real_shim_as_the_user "init"

    assert_success
    assert_owned_by_the_user "~/.config/farmy/.env", "~/.config/farmy/farmy.yml"
  end

  # Record 2026-10-29-1800: under sudo -E farmy acts for the user who ran sudo; the one-time hand-back covers farmy's own
  # folders only. These stage root's files, so they need a root runner, as the Mini's is.

  test "sudo -E farmy init on a fresh machine through the real shim makes the default home the user's who ran sudo, not root's" do
    on_a_fresh_machine
    host_git_identity "Dana Brooks", "dana@example.com"

    real_shim_under_sudo_e "init"

    assert_success
    assert_owned_by_the_user "~/.config/farmy", "~/.config/farmy/farmy.yml", "~/.config/farmy/.env", "~/.local/state/farmy"
  end

  test "a default home left root's by an earlier sudo -E is the user's again once the user's farmy has made the control container" do
    on_a_fresh_machine
    default_home_left_root_s

    real_shim_as_the_user "status"

    assert_success
    assert_owned_by_the_user "~/.config/farmy", "~/.config/farmy/farmy.yml", "~/.local/state/farmy", "~/.local/state/farmy/.work"
  end

  test "a shared containers folder of root's keeps its owner, and its farmy.yml and .env stay root's, when a plain user's farmy makes the control container for it" do
    shared = shared_folder_of_root_s

    real_shim_as_the_user "-C", shared, "status"

    assert_includes real_docker("inspect", "-f", "{{.State.Status}}", "farmy"), "running"
    assert_root_s shared, File.join(shared, "farmy.yml"), File.join(shared, ".env"), File.join(shared, "services")
  end
end
