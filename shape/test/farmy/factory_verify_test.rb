# On-demand verify: with factory verify: <command>, the agent runs farmy-verify in its container as often as it likes;
# it gets the command's output and exit code from a separate container. verify_service makes shop with verify: test
# and one iteration; its test/check.sh prints `args:` and each argument in brackets, `checking src/app.txt` on stderr,
# then `src/app.txt says fixed` (exit 0) or `src/app.txt does not say fixed yet` (exit 3). The agent's steps are
# command lines it runs in its container, which the fake runs for real.
class FactoryVerifyTest < AcceptanceTest
  test "a verify of a tree that passes gives the agent the command's stdout and stderr apart, and exit 0" do
    verify_service
    agent_plays({ writes: { "src/app.txt" => "fixed\n" }, steps: [{ run: "farmy-verify" }] })

    factory_start

    assert_agent_got 1, exit: 0, stdout: "src/app.txt says fixed", stderr: "checking src/app.txt"
    refute_agent_got 1, stdout: "checking src/app.txt", stderr: "src/app.txt says fixed"
  end

  test "a verify of a tree that fails gives the agent the command's output and its exit code" do
    verify_service
    agent_plays({ writes: { "src/app.txt" => "almost\n" }, steps: [{ run: "farmy-verify" }] })

    factory_start

    assert_agent_got 1, exit: 3, stdout: "src/app.txt does not say fixed yet", stderr: "checking src/app.txt"
  end

  test "the agent's arguments are appended to the verify command, each as a word of its own" do
    verify_service
    agent_plays({ steps: [{ run: "farmy-verify --name 'only login'" }] })

    factory_start

    assert_agent_got 1, stdout: "args: [--name] [only login]"
  end

  test "farmy-verify passes the command's output on as it comes: the first line reaches the agent before the command ends" do
    verify_service commands: { "progress" => "echo first line; sleep 3; echo second line" }, verify: "progress"
    agent_plays({ steps: [{ run: "farmy-verify" }] })

    factory_start

    assert_arrived_apart 1, "first line", "second line", by: 1
  end

  {
    124 => ["timeout 1 sleep 5", "it timed out"],
    126 => ["./test/check.sh", "a program it runs could not be executed"],
    127 => ["shop-lint-not-installed", "a program it runs was not found"]
  }.each do |code, (line, meaning)|
    test "a verify command that exits #{code} is reported to the agent as such, apart from a failing suite: #{meaning}" do
      verify_service commands: { "lint" => line }, verify: "lint"
      agent_plays({ steps: [{ run: "farmy-verify" }] })

      factory_start

      assert_agent_got 1, exit: code, stderr: "farmy-verify: the command exited #{code}: #{meaning}"
    end
  end

  test "a verify whose sidecar never becomes healthy tells the agent it could not run, naming the sidecar, with exit 125, and the run goes on to its gate" do
    verify_service sidecar: :health_checked
    verify_sidecars_unhealthy
    agent_plays({ writes: { "src/app.txt" => "fixed\n" }, steps: [{ run: "farmy-verify" }] })

    factory_start

    assert_agent_got 1, exit: 125, stderr: /farmy-verify: could not run: .*postgres/
    refute_agent_got 1, stdout: "src/app.txt says fixed"
    assert_success
  end

  test "with verify the agent's prompt names farmy-verify and the command it runs, even when factory/prompt.md says nothing of it" do
    verify_service
    write_file "factory/prompt.md", "Fix this: {{TASK}}\n"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })

    factory_start

    assert_last_agent_prompt "farmy-verify", "sh test/check.sh"
  end

  test "without verify in the profile the agent's container has no farmy-verify" do
    factory_service max_iterations: 1
    agent_plays({ steps: [{ run: "farmy-verify" }] })

    factory_start

    assert_agent_got 1, exit: 127, stderr: "not found"
  end

  test "a verify naming a command that is not under commands: is refused before the run starts, naming it" do
    verify_service verify: "lint"

    factory_start

    assert_exit 1
    assert_stderr "lint"
    assert_stderr "commands:"
    assert_agent_count 0
  end
end
