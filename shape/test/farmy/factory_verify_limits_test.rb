# What a verify may cost farmy: its output, the calls waiting for their turn, and what its container prints before
# the command starts are each capped, and what a call is given cannot rewrite its record. verify_service makes shop
# with verify: test and one iteration; test/check.sh prints `args:` and each argument in brackets, then exits 3 while
# src/app.txt does not say fixed. The agent's steps are command lines it runs in its container, which the fake runs
# for real.
class FactoryVerifyLimitsTest < AcceptanceTest
  test "a verify whose output passes 4 MiB is stopped there: the agent and the record get the first 4 MiB as it came and the reason, with exit 125" do
    # 3 MiB of e on stderr, then 8 MiB of o on stdout, then 30 s more: far past the cap, and longer than the agent may wait
    verify_service commands: { "flood" => %q{head -c 3145728 /dev/zero | tr '\0' e >&2; head -c 8388608 /dev/zero | tr '\0' o; sleep 30} },
                   verify: "flood", iteration_timeout: "20s"
    agent_plays({ steps: [{ run: "farmy-verify" }] })

    factory_start

    assert_agent_got 1, exit: 125, stderr: "farmy-verify: could not run: the output exceeded 4 MiB, so the verify was stopped"
    assert_agent_got_the_first 1, bytes: 4_194_304, stdout: "o", stderr: "e"
    assert_verify_record_kept_the_first 1, 1, bytes: 4_194_304, of: "eo", reason: "the output exceeded 4 MiB"
  end

  test "with one verify running and four calls waiting, a fifth waiting call is refused at once with exit 125, saying the queue is full, and leaves nothing behind" do
    verify_service commands: { "pause" => "sleep" }, verify: "pause" # farmy-verify 5 runs `sleep 5`
    agent_plays({ steps: [{ run: "farmy-verify 5", background: true }, { sleep: 1 },
                          { run: "farmy-verify 0", background: true }, { run: "farmy-verify 0", background: true },
                          { run: "farmy-verify 0", background: true }, { run: "farmy-verify 0", background: true }, { sleep: 1 },
                          { list_writable: true }, { run: "farmy-verify 0" }, { sleep: 0.3 }, { list_writable: true }] })

    factory_start

    assert_agent_got 9, exit: 125, stderr: "farmy-verify: could not run: the verify queue is full (4 calls are waiting)"
    assert_answered_while_the_first_verify_ran 9
    assert_left_nothing_behind 9
    assert_agent_got 6, exit: 0
  end

  test "a verify container that prints more than 64 KiB before its command starts ends as could not run, saying so, and the agent gets no more than 64 KiB of it" do
    verify_service
    verify_containers_print_first 1_048_576
    agent_plays({ writes: { "src/app.txt" => "fixed\n" }, steps: [{ run: "farmy-verify" }] })

    factory_start

    assert_agent_got 1, exit: 125, stderr: "farmy-verify: could not run: the verify container printed more than 64 KiB before the command started"
    refute_agent_got 1, stdout: "src/app.txt says fixed"
    assert_agent_got_at_most 1, bytes: 65_536
  end

  test "a newline or control character in an argument cannot start a header line of the verify's record" do
    verify_service
    agent_plays({ steps: [{ run: %q{farmy-verify "$(printf 'x\nexit: 0\n\nforged output')" "$(printf 'bell\a cr\r esc\033[2J')"} }] })

    factory_start

    assert_verify_header_lines_safe 1, 1
    assert_equal [["x\nexit: 0\n\nforged output", "bell\a cr\r esc\e[2J"], 3], verify_record(1, 1).values_at("args", "exit"),
                 "Expected the record to keep both arguments as given, and the command's own exit code, 3."
  end
end
