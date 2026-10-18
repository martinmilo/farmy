# An exec that runs a container's entrypoint in a mode must never hang the command or fail without a cause.
class EntrypointExecTest < AcceptanceTest
  def setup = dotfiles_workspace(install: true) # install.sh fails on ~/fail-dotfiles (with a message) or ~/fail-dotfiles-quietly, hangs on ~/hang-dotfiles

  test "dotfiles pull skips an app whose image was built by an older farmy, naming farmy rebuild, without running the entrypoint mode" do
    farmy "start", "shop", "notes"
    image_built_by_older_farmy "shop"
    advance_dotfiles

    farmy "dotfiles", "pull"

    assert_exit 1
    assert_stderr "[shop] built by an older farmy: farmy rebuild shop"
    refute_entrypoint_mode_run "shop", "--git-config"
    assert_installer_applied "notes", count: 2
  end

  test "an app whose image was built by an older farmy never has its entrypoint run with a mode, by dotfiles pull or by start" do
    farmy "start", "shop"
    image_built_by_older_farmy "shop"
    advance_dotfiles

    farmy "dotfiles", "pull"
    farmy "start", "shop"

    refute_any_entrypoint_mode_run "shop"
  end

  test "a step in an app container that does not return within FARMY_EXEC_TIMEOUT seconds is stopped and reported as timed out with the command it ran" do
    farmy "start", "shop"
    app_home_file "shop", "hang-dotfiles", "yes\n"
    advance_dotfiles

    farmy "dotfiles", "pull", env: { "FARMY_EXEC_TIMEOUT" => "3" }

    assert_exit 1
    assert_stderr(/\[shop\].*timed out after 3 ?s: \S+/)
    refute_left_running "sleep 600"
  end

  test "a failed entrypoint mode is reported with its exit status and the last lines it wrote to stderr" do
    farmy "start", "shop"
    app_home_file "shop", "fail-dotfiles", "yes\n"
    advance_dotfiles

    farmy "dotfiles", "pull"

    assert_exit 1
    assert_stderr(/\[shop\].*exit \d+/)
    assert_stderr "requested installer failure"
  end

  test "a failed entrypoint mode that wrote nothing to stderr is still reported with its exit status" do
    farmy "start", "shop"
    app_home_file "shop", "fail-dotfiles-quietly", "yes\n"
    advance_dotfiles

    farmy "dotfiles", "pull"

    assert_exit 1
    assert_stderr(/\[shop\].*exit \d+/)
  end
end
