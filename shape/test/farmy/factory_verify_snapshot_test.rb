# What a verify tests and what the agent keeps: farmy-verify tests a snapshot of the agent's tree made as the
# iteration commit would make it, and changes nothing the agent sees. verify_service makes shop with verify: test and
# one iteration; test/check.sh (protected) prints `src/app.txt says fixed` (exit 0) or `src/app.txt does not say fixed
# yet` (exit 3), and a comment in it says `kept from the agent`, which it never prints.
class FactoryVerifySnapshotTest < AcceptanceTest
  test "a verify runs the protected tests as the run started them, not the agent's edit of them" do
    verify_service
    agent_plays({ writes: { "test/check.sh" => "echo all good\n" }, steps: [{ run: "farmy-verify" }] })

    factory_start

    assert_agent_got 1, exit: 3, stdout: "src/app.txt does not say fixed yet"
    refute_agent_got 1, stdout: "all good"
  end

  test "a verify leaves the agent's tree as it was, its edits to protected files and outside writes included" do
    verify_service writes: ["src/"]
    agent_plays({ writes: { "src/app.txt" => "fixed\n", "test/check.sh" => "echo all good\n", "notes.txt" => "try a fixed greeting\n" },
                  steps: [{ run: "farmy-verify" }, { run: "cat test/check.sh notes.txt src/app.txt" }] })

    factory_start

    assert_agent_got 1, exit: 0, stdout: "src/app.txt says fixed"
    assert_agent_got 2, exit: 0, stdout: "echo all good\ntry a fixed greeting\nfixed\n"
  end

  test "a verify's commit never reaches the run branch: the pushed branch holds only the iteration's commit" do
    verify_service
    agent_plays({ writes: { "src/app.txt" => "fixed\n" }, steps: [{ run: "farmy-verify" }, { run: "farmy-verify" }] })

    factory_start

    assert_agent_got 2, exit: 0
    assert_pushed "farmy/shop/#{run_id}", commits: ["farmy: iteration 1"]
  end

  test "a passing verify is not a passing gate: the gate tests what the agent leaves at the end" do
    verify_service
    agent_plays({ writes: { "src/app.txt" => "fixed\n" }, steps: [{ run: "farmy-verify" }, { writes: { "src/app.txt" => "broken again\n" } }] })

    factory_start

    assert_agent_got 1, exit: 0
    assert_exit 1
    assert_stdout "max_iterations"
    refute_pushed
  end

  test "a hidden folder cannot be read in the agent's container, yet the verify runs the tests in it" do
    verify_service hidden: ["test/"]
    agent_plays({ steps: [{ run: "cat /workspace/test/check.sh" }, { run: "farmy-verify" }] })

    factory_start

    assert_agent_got 1, exit: 1, stderr: "No such file"
    assert_agent_got 2, exit: 3, stdout: "src/app.txt does not say fixed yet"
  end

  test "after a verify no file the agent's container can see holds anything of the hidden folder" do
    verify_service hidden: ["test/"]
    agent_plays({ steps: [{ run: "farmy-verify" }, { find: "kept from the agent" }] })

    factory_start

    assert_agent_got 1, exit: 3
    assert_agent_found_nowhere "kept from the agent"
  end
end
