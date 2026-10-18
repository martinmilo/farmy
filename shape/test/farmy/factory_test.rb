# The factory loop: an agent works on a run of its own until a separate gate passes; nothing it says counts.
# Each test starts from an empty folder; factory_service sets up shop (its check passes once src/app.txt
# says fixed), and the agent does what agent_plays says, iteration by iteration.
class FactoryTest < AcceptanceTest
  test "factory start clones the checkout into a run volume, on a new branch from the remote's base, and leaves the developer's checkout as it was" do
    factory_service
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_success
    assert_volume "shop-run-#{run_id}"
    assert_equal "fixed\n", run_file(run_id, "src/app.txt")
    assert_checkout_unchanged
  end

  test "a loop that goes red, red, green ends green after three iterations, and the run branch with three commits is pushed" do
    factory_service max_iterations: 5
    agent_plays({ writes: { "src/app.txt" => "almost\n" } }, { writes: { "src/app.txt" => "nearly\n" } }, { writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_success
    assert_stdout "green"
    assert_pushed "farmy/shop/#{run_id}", commits: ["farmy: iteration 1", "farmy: iteration 2", "farmy: iteration 3"]
  end

  test "a run that ends red at max_iterations pushes nothing" do
    factory_service max_iterations: 2
    agent_plays({ writes: { "src/app.txt" => "almost\n" } }, { writes: { "src/app.txt" => "nearly\n" } })

    factory_start

    assert_exit 1
    assert_stdout "max_iterations"
    refute_pushed
  end

  test "an agent that edits a protected file sees that edit gone at the gate" do
    factory_service max_iterations: 1
    agent_plays({ writes: { "test/check.sh" => "exit 0\n" } })

    factory_start

    assert_exit 1
    assert_stdout "max_iterations"
    assert_equal "grep -q fixed src/app.txt\n", run_file(run_id, "test/check.sh")
  end

  test "an agent that prints tests pass with a red suite does not produce green" do
    factory_service max_iterations: 2
    agent_plays({ says: "All tests pass. Done." }, { says: "All tests pass. Done." })

    factory_start

    assert_exit 1
    assert_stdout "stalled"
    refute_pushed
  end

  test "a hidden folder is covered in the agent's container, and what the agent writes there reaches no commit" do
    factory_service protects: ["test/"], hidden: ["test/"], max_iterations: 1
    agent_plays({ writes: { "test/check.sh" => "exit 0\n", "src/app.txt" => "fixed\n" } })

    factory_start

    assert_success
    assert_covered "agent", "/workspace/test"
    assert_equal "grep -q fixed src/app.txt\n", run_file(run_id, "test/check.sh")
  end

  test "the agent's container has no git history, no agent socket, no git route and no farmy-shared" do
    factory_service
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_covered "agent", "/workspace/.git"
    refute_run_env "agent", "SSH_AUTH_SOCK"
    refute_run_env "agent", "DEV_GIT_ROUTES"
    refute_run_volume "agent", "farmy-shared"
    refute_run_volume "agent", "shop-keys-agent"
  end

  test "the git container is the only run container with the agent socket" do
    factory_service
    with_ssh_git_route # an SSH route for github.com: the service's app container gets the agent socket
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_run_env "git", "SSH_AUTH_SOCK", "/run/farmy-keys/agent.sock"
    refute_run_env "agent", "SSH_AUTH_SOCK"
    refute_run_env "test", "SSH_AUTH_SOCK"
    refute_run_volume "test", "shop-keys-agent"
  end

  test "the gate runs in a new container each iteration, the run volume read-only and a scratch tmpfs" do
    factory_service max_iterations: 2
    agent_plays({ writes: { "src/app.txt" => "almost\n" } }, { writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_equal 2, run_containers("test").map { |r| r["name"] }.uniq.size
    assert_run_mount "test", "shop-run-#{run_id}", at: "/workspace", readonly: true
    assert_covered "test", "/scratch"
  end

  test "the prompt carries the task, the iteration and the last lines of the previous test output" do
    factory_service max_iterations: 2
    agent_plays({ writes: { "src/app.txt" => "almost\n" } }, { writes: { "src/app.txt" => "fixed\n" } })

    factory_start task: "Fix the greeting in src/app.txt."

    assert_includes agent_prompts[0], "Fix the greeting in src/app.txt."
    assert_includes agent_prompts[0], "1 of 2"
    assert_includes agent_prompts[1], "2 of 2"
    assert_includes agent_prompts[1], "exit 1"
  end

  test "factory/prompt.md in the containers folder replaces the prompt template" do
    factory_service max_iterations: 1
    write_file "factory/prompt.md", "TASK={{TASK}} ITERATION={{ITERATION}}\n{{TEST_OUTPUT}}\n"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start task: "Fix it."

    assert_includes agent_prompts[0], "TASK=Fix it. ITERATION=1 of 1"
  end

  test "the agent reaches its model through the run's own broker, which holds the agent's route and no git route" do
    factory_service
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_run_env "agent", "ANTHROPIC_BASE_URL", "http://keys:9181/anthropic"
    assert_run_env "agent", "ANTHROPIC_API_KEY", "via-farmy-keys"
    assert_loaded_into "shop-run-#{run_id}-keys", "ANTHROPIC_API_KEY"
    refute_secret_anywhere "sk-ant-api03-4f9e"
  end

  test "a run takes the agent's key from the holder: no value on stdin is needed" do
    factory_service # the key was given to farmy start, and the control container holds it
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start stdin: ""

    assert_success
    assert_loaded_into "shop-run-#{run_id}-keys", "ANTHROPIC_API_KEY"
  end

  test "an agent that exits non-zero having changed nothing ends the run agent_failed" do
    factory_service
    agent_plays({ says: "Error: model overloaded", exit: 1 })

    factory_start

    assert_exit 1
    assert_stdout "agent_failed"
    assert_equal 0, run_containers("test").size
  end

  test "an agent that runs past iteration_timeout is stopped and the run ends timeout" do
    factory_service iteration_timeout: "1s"
    agent_plays({ idle: 5 })

    factory_start

    assert_exit 1
    assert_stdout "timeout"
  end

  test "a test container Docker refuses to start ends the run test_failed_to_run" do
    factory_service
    fail_role "test"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_exit 1
    assert_stdout "test_failed_to_run"
    refute_pushed
  end

  test "factory cancel stops a running run and marks it cancelled" do
    factory_service iteration_timeout: "60s"
    agent_plays({ idle: 30 })
    factory_start wait: false
    wait_for_agent

    farmy "factory", "cancel", run_id
    farmy "factory", "list"

    assert_stdout(/#{run_id}\s+shop\s+cancelled/)
  end

  test "a run whose controller is gone reads interrupted, and its state survives" do
    factory_service iteration_timeout: "60s"
    agent_plays({ idle: 30 })
    factory_start wait: false
    id = run_id
    wait_for_agent
    kill_controller id

    farmy "factory", "list"
    assert_stdout(/#{id}\s+shop\s+interrupted/)
    farmy "factory", "show", id
    assert_stdout "interrupted"
  end

  test "factory show prints the branch, the result and the last test output, and factory log an iteration's logs" do
    factory_service max_iterations: 2
    agent_plays({ writes: { "src/app.txt" => "almost\n", "src/note.txt" => "x" }, says: "working on it" }, { writes: { "src/app.txt" => "fixed\n" } })
    factory_start
    id = run_id

    farmy "factory", "show", id
    assert_stdout "farmy/shop/#{id}"
    assert_stdout "green"

    farmy "factory", "log", id, "1"
    assert_stdout "working on it"
  end

  test "status --json lists a service's runs with phase, iteration and result" do
    factory_service max_iterations: 2
    agent_plays({ writes: { "src/app.txt" => "almost\n" } }, { writes: { "src/app.txt" => "fixed\n" } })
    factory_start
    id = run_id

    farmy "status", "--json"

    run = service_json("shop")["runs"].find { |r| r["id"] == id }
    assert_equal({ "phase" => "done", "iteration" => 2, "max_iterations" => 2, "result" => "green", "branch" => "farmy/shop/#{id}" }, run.slice("phase", "iteration", "max_iterations", "result", "branch"))
  end

  test "factory start without factory: in the definition is refused naming factory:" do
    factory_service
    write_file "services/shop.yml", read_file("services/shop.yml").sub(/^factory:.*\z/m, "")

    factory_start

    assert_exit 1
    assert_stderr "factory:"
    assert_stderr "services/shop.yml"
  end

  test "a factory test that is not a command of the service is refused naming it" do
    factory_service test: "spec"

    factory_start

    assert_exit 1
    assert_stderr "spec"
    assert_stderr "commands:"
  end

  test "a factory agent with neither an api route nor a token_env is refused naming both" do
    factory_service
    write_file "farmy.yml", "agents:\n  mytool:\n    install: ~\n    login: .mytool\n    headless_login: mytool login\n    headless: {command: mytool run, prompt: argument}\n"
    write_file "services/shop.yml", read_file("services/shop.yml").sub("agent: claude", "agent: mytool")

    factory_start

    assert_exit 1
    assert_stderr "mytool"
    assert_stderr "api"
    assert_stderr "token_env"
  end

  test "factory start for a service that is not running is refused naming farmy start" do
    factory_service
    farmy "stop", "shop"

    factory_start

    assert_exit 1
    assert_stderr "farmy start shop"
  end

  test "a suite that writes into its tree passes at the gate: it runs on an export of the commit in its scratch area" do
    factory_service max_iterations: 1, check: "mkdir -p tmp && echo ran > tmp/test.log && grep -q fixed src/app.txt\n"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_success
    assert_stdout "green"
  end

  test "what the agent left uncommitted is not in the gate's export" do
    factory_service max_iterations: 1, files: { ".gitignore" => "*.log\n" }, check: "test ! -e debug.log && grep -q fixed src/app.txt\n"
    agent_plays({ writes: { "src/app.txt" => "fixed\n", "debug.log" => "left behind, ignored by git\n" } })

    factory_start

    assert_success
    assert_stdout "green"
  end

  test "the gate reaches its own copies of sidecars by name on an internal network while the developer sidecars and agent stay separate" do
    factory_service sidecar: true # compose: postgres, container_name shop-pg
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_success
    assert_gate_sidecar_copy run_id, service: "postgres", original: "shop-pg"
    refute_includes run_containers("agent").flat_map { |r| Array(r["networks"]) }, run_containers("test").first["networks"].first
  end

  test "with factory.gate.network: none the gate has no network and no sidecar joins" do
    factory_service sidecar: true, gate: { "network" => "none" }
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_success
    assert_equal ["none"], run_containers("test").flat_map { |r| Array(r["networks"]) }.uniq
    refute_sidecar_joins
  end

  test "the git container gets the proxy variables and an ssh ProxyCommand through the mesh" do
    factory_service
    with_ssh_git_route
    with_mesh_egress
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_success
    assert_run_env "git", "HTTPS_PROXY", "http://farmy-egress:1055"
    assert_run_git_config "git", "core.sshCommand", /ProxyCommand='nc -X 5 -x farmy-egress:1055 %h %p'/
  end

  test "factory prune removes the volumes of finished runs and keeps their state" do
    factory_service
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })
    factory_start
    id = run_id

    farmy "factory", "prune"

    assert_success
    refute_volume "shop-run-#{id}"
    farmy "factory", "show", id
    assert_stdout "green"
    assert_stdout "removed"
  end

  test "factory prune --older-than 7d keeps a run that ended now" do
    factory_service
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })
    factory_start
    id = run_id

    farmy "factory", "prune", "--older-than", "7d"

    assert_success
    assert_volume "shop-run-#{id}"
  end

  test "factory show prints the run volume and its size" do
    factory_service
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })
    factory_start
    id = run_id

    farmy "factory", "show", id

    assert_stdout(/^volume\s+shop-run-#{id}\s+\d/)
  end

  test "every git container of a run runs as the checkout's owner, and the run volume belongs to that user" do
    factory_service
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_success
    assert_run_user "git", 1001
    assert_volume_owner "shop-run-#{run_id}", 1001
  end

  test "a checkout owned by another user is refused with git's first line that names the cause, and git's full output is in the run's git.log" do
    factory_service
    checkout_owned_by 0

    factory_start

    assert_exit 1
    assert_stderr "detected dubious ownership in repository at '/src/.git'"
    refute_stderr "and the repository exists"
    assert_includes run_git_log, "Could not read from remote repository."
  end

  test "every git container of a run is on the service's network and on farmy, where the egress node resolves; the agent's and the gate's are not on farmy" do
    factory_service
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_success
    run_containers("git").each { |r| assert_equal ["farmy", "shop_default"], Array(r["networks"]).sort, "Expected the git container #{r["name"]} on the service's network and on farmy.#{transcript}" }
    refute_includes run_containers("agent").flat_map { |r| Array(r["networks"]) }, "farmy"
    refute_includes run_containers("test").flat_map { |r| Array(r["networks"]) }, "farmy"
  end

  test "destroy removes the service's run volumes" do
    factory_service
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })
    factory_start
    id = run_id

    farmy "destroy", "shop", stdin: "y\n"

    assert_success
    refute_volume "shop-run-#{id}"
  end

  test "an agent in token mode reaches its model through a filtering proxy on internal run networks, never outward farmy" do
    factory_service model: :token, egress: true
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_success
    assert_agents_filtered
  end

  test "in api-key mode the agent is on internal run networks with its broker and filtering proxy" do
    factory_service egress: true
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_success
    assert_agents_filtered
  end

  [:token, :api].each do |model|
    test "a run in #{model} mode removes only what it made: no line about a container or network that is not there" do
      factory_service model: model
      agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

      factory_start

      assert_success
      refute_stderr "No such container"
      refute_stderr(/network .* not found/)
    end
  end

  test "show names the first cause line of the agent's log next to agent_failed" do
    factory_service
    agent_plays({ says: "Starting…\nAPI Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)\n", exit: 1 })
    factory_start
    id = run_id

    farmy "factory", "show", id

    assert_stdout(/agent_failed.*API Error: Can't reach the API server/)
  end

  test "show says (no output) under the last test output of a gate that passed printing nothing" do
    factory_service # the check is grep -q: it prints nothing
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })
    factory_start
    id = run_id

    farmy "factory", "show", id

    assert_stdout "(no output)"
  end
end
