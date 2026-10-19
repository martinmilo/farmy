# The test kit's own guarantees, as a real-Docker run on a Docker-only host relies on them.
#
#   runner_started_daemon          a process that was running before the test began and keeps starting children
#                                  during it, as dockerd does in a docker:dind container that then runs bin/verify
#   assert_leak_check_leaves_the_daemon   the leak check neither reports nor kills it or its children
#   a_detached_process_is_left_running        the test itself starts `sleep 300` detached (setsid) and does not stop it
#   assert_leak_check_kills_and_reports "sleep"
#   assert_needing_docker_where_none_answers fails_naming: "REQUIRE_DOCKER" · skips:   with REQUIRE_DOCKER set to "1" or unset
module Kit
  def runner_started_daemon
    @daemon = Process.spawn("sh", "-c", "while :; do sleep 0.2; done", pgroup: true)
    sleep 0.3
    Processes.mark # as before_setup did, had the daemon been started before the test
  end

  def assert_leak_check_leaves_the_daemon
    sleep 0.5 # the daemon has started children since
    left = Processes.sweep(grace: 0)
    assert_empty left, "Expected the leak check to leave alone a process that was running before the test began, and the children it starts during the test (as a docker:dind container's dockerd, started before bin/verify, starts shims); it reported and killed: #{left.inspect}."
    assert process_alive?(@daemon), "Expected the process from before the test to be running still after the leak check."
  end

  def a_detached_process_is_left_running
    pid = Process.spawn("setsid", "sh", "-c", "sleep 300 & exit 0", %i[out err] => File::NULL)
    Process.wait(pid)
  end

  def assert_leak_check_kills_and_reports(command)
    left = Processes.sweep(grace: 0)
    assert left.any? { |line| line.start_with?(command) }, "Expected the leak check to report the #{command} the test started and left running; it reported: #{left.inspect}."
    refute Processes.descendants.any? { |_, state, line| state != "Z" && line.start_with?(command) }, "Expected the leak check to have killed the #{command} the test left."
  end

  def assert_needing_docker_where_none_answers(fails_naming: nil, skips: false)
    define_singleton_method(:real_docker?) { false }
    saved = ENV["REQUIRE_DOCKER"]
    fails_naming ? ENV["REQUIRE_DOCKER"] = "1" : ENV.delete("REQUIRE_DOCKER")
    raised = begin
      require_real_docker
      nil
    rescue Minitest::Assertion => e
      e
    end
    if skips
      assert_kind_of Minitest::Skip, raised, "Expected a test that needs a real Docker to be skipped where none answers and REQUIRE_DOCKER is unset; it was #{raised ? raised.class : "let run"}."
    else
      assert raised && !raised.is_a?(Minitest::Skip), "Expected a test that needs a real Docker to fail, not be skipped, where none answers and REQUIRE_DOCKER=1; it was #{raised ? "skipped" : "let run"}."
      assert_includes raised.message, fails_naming, "Expected the failure to name #{fails_naming}."
    end
  ensure
    saved ? ENV["REQUIRE_DOCKER"] = saved : ENV.delete("REQUIRE_DOCKER")
  end

  def teardown
    super
    Process.kill("KILL", -@daemon) rescue nil if @daemon
    Process.wait(@daemon) rescue nil if @daemon
  end

  private

  def process_alive?(pid) = File.exist?("/proc/#{pid}") && !File.read("/proc/#{pid}/stat").split(") ").last.start_with?("Z")
end
