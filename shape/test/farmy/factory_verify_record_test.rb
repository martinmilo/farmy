# The run record keeps every verify: a log per call beside the iteration's other files, a count per iteration in
# state.json, and the count in factory show. verify_service makes shop with verify: test and one iteration; test/check.sh
# prints `args:` and each argument in brackets, `checking src/app.txt` on stderr, then `src/app.txt says fixed` (exit 0)
# or `src/app.txt does not say fixed yet` (exit 3).
class FactoryVerifyRecordTest < AcceptanceTest
  test "every verify is kept as iteration-<i>.verify-<k>.log: its args, start, end and exit code, then its full output" do
    verify_service
    agent_plays({ steps: [{ run: "farmy-verify" }, { writes: { "src/app.txt" => "fixed\n" } }, { run: "farmy-verify --name 'only login'" }] })

    factory_start

    assert_equal [[], 3], verify_record(1, 1).values_at("args", "exit"), "Expected the first verify's record: no args, exit 3."
    assert_equal [["--name", "only login"], 0], verify_record(1, 2).values_at("args", "exit"), "Expected the second verify's record: its two args, exit 0."
    assert_utc_timestamp verify_record(1, 2)["started"], "the second verify's started"
    assert_utc_timestamp verify_record(1, 2)["ended"], "the second verify's ended"
    assert_includes verify_record(1, 2)["output"], "src/app.txt says fixed\n"
    assert_includes verify_record(1, 2)["output"], "checking src/app.txt\n"
  end

  test "state.json counts each iteration's verifies, and a verify is not an iteration" do
    verify_service max_iterations: 2
    agent_plays({ steps: [{ run: "farmy-verify" }, { run: "farmy-verify" }] }, { writes: { "src/app.txt" => "fixed\n" }, steps: [{ run: "farmy-verify" }] })

    factory_start

    assert_equal [{ "iteration" => 1, "count" => 2 }, { "iteration" => 2, "count" => 1 }], run_state["verifies"], "Expected state.json's verifies: one count per iteration."
    assert_equal 2, run_state["iteration"], "Expected two iterations, the verifies not among them."
    assert_equal [1, 2], run_state["verdicts"].map { |v| v["iteration"] }, "Expected a verdict for each iteration's gate and none for a verify."
  end

  test "factory show lists each iteration's verify count" do
    verify_service max_iterations: 2
    agent_plays({ steps: [{ run: "farmy-verify" }, { run: "farmy-verify" }] }, { writes: { "src/app.txt" => "fixed\n" } })
    factory_start

    farmy "factory", "show", run_id

    assert_stdout(/^\s+1\s.*\bverifies 2$/)
    assert_stdout(/^\s+2\s.*\bverifies 0$/)
  end
end
