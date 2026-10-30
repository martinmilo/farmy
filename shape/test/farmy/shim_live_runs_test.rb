# The shim never replaces a control container that live runs are in (records 2026-10-26-2126 and 2026-10-29-1215):
# replacing it ends them. A live run is a factory run or the session. A factory run is staged the two ways a shim can
# see it with docker alone: docker top of the control container lists `/usr/local/bin/farmy factory run <id>`, and its
# agent container (farmy.run=<id>, farmy.role=agent) is running. The session is staged as its tmux server in docker top.
class ShimLiveRunsTest < AcceptanceTest
  def setup = workspace("workshop") # shop and notes are defined; each test makes the control container it needs

  # ── a folder switch (record 2026-10-29-1215) ──

  test "a control container serving another folder is not replaced while a factory run is live in it: the shim refuses with one line naming that folder, 1 live run, and the two ways out" do
    control_container_for_another_folder
    factory_run_live "shop", "20261026-091500-3f9c"

    shim "start", "shop"

    assert_refused_for_the_folder the_other_folder, live: 1
    assert_run_still_live "20261026-091500-3f9c"
  end

  test "the session counts as a live run: a control container serving another folder with only its session live is not replaced, and the refusal says 1 live run" do
    control_container_for_another_folder
    session_live

    shim "start", "shop"

    assert_refused_for_the_folder the_other_folder, live: 1
    assert_session_still_live
  end

  test "the refusal counts every live run in the control container: two factory runs and the session make 3 live runs" do
    control_container_for_another_folder
    factory_run_live "shop", "20261026-091500-3f9c"
    factory_run_live "notes", "20261026-093012-b71e"
    session_live

    shim "start", "shop"

    assert_refused_for_the_folder the_other_folder, live: 3
  end

  { "farmy stop" => %w[stop], "farmy factory cancel" => %w[factory cancel 20261026-091500-3f9c], "farmy init" => %w[init],
    "a bare farmy, which starts the session" => [] }.each do |what, words|
    test "#{what} is refused too while the control container serves another folder with a live run, as every command that is not read-only is" do
      control_container_for_another_folder
      factory_run_live "shop", "20261026-091500-3f9c"

      shim(*words)

      assert_refused_for_the_folder the_other_folder, live: 1
      assert_run_still_live "20261026-091500-3f9c"
    end
  end

  test "farmy -C with the folder the control container serves runs the command in that container, which is kept with its live run" do
    control_container_for_another_folder
    factory_run_live "shop", "20261026-091500-3f9c"

    shim "-C", the_other_folder, "factory", "cancel", "20261026-091500-3f9c"

    assert_success
    assert_control_container_kept
    assert_ran_in_control_container "farmy factory cancel 20261026-091500-3f9c"
  end

  test "a control container serving the default home is not replaced from a project folder while its session is live: the refusal names ~/.config/farmy" do
    control_container_for_the_default_home
    session_live

    shim "start", "shop" # in the test's folder, a project folder (FARMY_DIR names it)

    assert_refused_for_the_folder "~/.config/farmy", live: 1
    assert_session_still_live
  end

  test "farmy -C ~/.config/farmy runs the command in the control container serving the default home, which is kept with its live session" do
    control_container_for_the_default_home
    session_live

    shim "-C", machine_path("~/.config/farmy"), "status"

    assert_success
    assert_control_container_kept
    assert_ran_in_control_container "farmy status"
  end

  test "a control container serving another folder is kept when docker top fails, since the shim cannot tell whether runs are live in it: the command is refused, naming the daemon's error and farmy -C that folder" do
    control_container_for_another_folder
    docker_top_fails

    shim "start", "shop"

    assert_refused_unable_to_count the_other_folder
  end

  test "a control container serving another folder, with no run live in it, is replaced by one for this folder" do
    control_container_for_another_folder

    shim "status"

    assert_success
    assert_control_container_made_anew_for_this_folder
    assert_ran_in_control_container "farmy status"
  end

  # ── read-only commands (record 2026-10-29-1800) ──

  { "farmy status" => %w[status], "farmy status --json" => %w[status --json], "farmy help" => %w[help], "farmy config path" => %w[config path],
    "farmy factory list" => %w[factory list], "farmy factory show 20261029-101500-8a2d" => %w[factory show 20261029-101500-8a2d],
    "farmy factory log 20261029-101500-8a2d" => %w[factory log 20261029-101500-8a2d], "farmy logs shop" => %w[logs shop],
    "farmy egress log" => %w[egress log], "farmy tui --version" => %w[tui --version] }.each do |what, words|
    test "#{what}, a read-only command, runs while the control container serves another folder with a live run: in a container of its own for this folder, and the control container is kept with its run" do
      control_container_for_another_folder
      factory_run_live "shop", "20261026-091500-3f9c"

      shim(*words)

      assert_success
      assert_control_container_kept
      assert_run_still_live "20261026-091500-3f9c"
      assert_ran_on_its_own_for_this_folder what
    end
  end

  test "farmy status runs in a container of its own for this folder when docker top of a control container serving another folder fails, and that container is kept" do
    control_container_for_another_folder
    docker_top_fails

    shim "status"

    assert_success
    assert_control_container_kept
    assert_ran_on_its_own_for_this_folder "farmy status"
  end

  test "farmy --version answers while the control container serves another folder with a live run, and nothing is handed to that container" do
    control_container_for_another_folder
    factory_run_live "shop", "20261026-091500-3f9c"

    shim "--version"

    assert_success
    assert_stdout "farmy #{SHIPPED} ("
    assert_control_container_kept
    assert_run_still_live "20261026-091500-3f9c"
  end

  # ── another farmy version or an out-of-date image (record 2026-10-26-2126) ──

  test "a control container that runs another farmy version is not replaced while a factory run is live in it: the shim refuses, naming the run, that version and farmy factory cancel" do
    control_container_up
    control_container_runs_farmy "0.1.0"
    factory_run_live "shop", "20261026-091500-3f9c"

    shim "status"

    assert_refused_keeping_live_run "20261026-091500-3f9c"
    assert_stderr "0.1.0"
    assert_stderr "farmy factory cancel"
  end

  test "a control container that runs another farmy version is not replaced while only its session is live: the shim refuses, naming the session" do
    control_container_up
    control_container_runs_farmy "0.1.0"
    session_live

    shim "status"

    assert_exit 1
    assert_stderr "session"
    assert_control_container_kept
    assert_session_still_live
  end

  test "init does not replace a control container whose image is out of date while a factory run is live in it: the shim refuses, naming the run and the image" do
    control_container_up
    control_image_out_of_date
    factory_run_live "shop", "20261026-091500-3f9c"

    shim "init"

    assert_refused_keeping_live_run "20261026-091500-3f9c"
    assert_stderr "image"
  end

  test "the refusal names every factory run live in a control container that runs another farmy version" do
    control_container_up
    control_container_runs_farmy "0.1.0"
    factory_run_live "shop", "20261026-091500-3f9c"
    factory_run_live "notes", "20261026-093012-b71e"

    shim "status"

    assert_exit 1
    assert_stderr "20261026-091500-3f9c"
    assert_stderr "20261026-093012-b71e"
  end

  test "a control container that runs another farmy version is kept when docker top fails, since the shim cannot tell whether runs are live in it: the command is refused, naming the daemon's error" do
    control_container_up
    control_container_runs_farmy "0.1.0"
    docker_top_fails

    shim "status"

    assert_refused_unable_to_count
  end

  test "farmy stop naming a service is refused like any other command while the control container is due to be replaced and a run is live in it" do
    control_container_up
    control_container_runs_farmy "0.1.0"
    factory_run_live "shop", "20261026-091500-3f9c"

    shim "stop", "shop"

    assert_refused_keeping_live_run "20261026-091500-3f9c"
  end

  test "farmy stop with no name does not replace a control container that runs another farmy version while a run is live in it: stop runs in the kept container" do
    control_container_up
    control_container_runs_farmy "0.1.0"
    factory_run_live "shop", "20261026-091500-3f9c"

    shim "stop"

    assert_success
    assert_control_container_kept
    assert_run_still_live "20261026-091500-3f9c"
    assert_ran_in_control_container "farmy stop"
  end

  test "farmy factory cancel is not refused: it runs in the control container the run is live in, which is kept, since only there can it stop the controller" do
    control_container_up
    control_container_runs_farmy "0.1.0"
    factory_run_live "shop", "20261026-091500-3f9c"

    shim "factory", "cancel", "20261026-091500-3f9c"

    assert_success
    assert_control_container_kept
    assert_ran_in_control_container "farmy factory cancel 20261026-091500-3f9c"
  end

  test "a control container that runs farmy 0.2.0, an earlier release, is replaced by one of this version when no run is live in it, as one of another version is" do
    control_container_up
    control_container_runs_farmy "0.2.0"

    shim "status"

    assert_success
    assert_control_container_made_anew_for_this_folder
    assert_control_container_runs_farmy SHIPPED
  end

  # ── reading the container ──

  test "a control container whose docker inspect fails is kept, not replaced, and the command is refused, naming the daemon's error: who farmy runs as in it is read from it" do
    control_container_up
    control_container_inspect "error"

    shim "status"

    assert_refused_unreadable "context deadline exceeded"
  end

  test "a control container whose docker inspect answers nothing is kept, not replaced, and the command is refused, saying it could not be read" do
    control_container_up
    control_container_inspect "empty"

    shim "status"

    assert_refused_unreadable "could not be read"
  end

  test "a control container removed by hand (docker rm -f farmy, as troubleshooting says) is made anew by the next command, though the farmy network it was on is still there" do
    control_container_up
    control_container_removed_by_hand

    shim "status"

    assert_success
    assert_control_container_made_anew_for_this_folder
    assert_ran_in_control_container "farmy status"
  end
end
