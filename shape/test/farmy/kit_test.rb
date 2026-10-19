# The test kit, as a real-Docker run relies on it: in a docker:dind container the Docker daemon is started
# before bin/verify, and with JOBS=1 the runner takes over the shell that started it.
class KitTest < AcceptanceTest
  test "the leak check never kills or reports a process that was running before the test began, nor the children it starts during the test" do
    runner_started_daemon

    assert_leak_check_leaves_the_daemon
  end

  test "the leak check kills and reports a process the test started and left running" do
    a_detached_process_is_left_running

    assert_leak_check_kills_and_reports "sleep"
  end

  test "with REQUIRE_DOCKER=1 a test that needs a real Docker fails where none answers, naming REQUIRE_DOCKER" do
    assert_needing_docker_where_none_answers fails_naming: "REQUIRE_DOCKER"
  end

  test "without REQUIRE_DOCKER a test that needs a real Docker is skipped where none answers" do
    assert_needing_docker_where_none_answers skips: true
  end
end
