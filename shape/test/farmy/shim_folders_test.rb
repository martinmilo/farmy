# The shim resolves farmy's folder on the host (the control container sees neither the current folder's parents
# nor the host's HOME), creates and mounts what it resolved at the same paths, and hands the result to farmy in
# the control container. Record 2026-10-29-0926.
class ShimFoldersTest < AcceptanceTest
  def setup = on_a_fresh_machine # HOME is the test's own; nothing tells farmy its folder unless the test does

  test "on a fresh machine the shim creates ~/.config/farmy and ~/.local/state/farmy and mounts both into the control container at their own paths" do
    shim "status"

    assert_mounted_at_own_path "farmy", "~/.config/farmy"
    assert_mounted_at_own_path "farmy", "~/.local/state/farmy"
  end

  test "on a macOS host the shim mounts the same two folders, and nothing goes under ~/Library" do
    macos_host

    shim "status"

    assert_mounted_at_own_path "farmy", "~/.config/farmy"
    assert_mounted_at_own_path "farmy", "~/.local/state/farmy"
    refute_machine_path "~/Library"
  end

  test "from a subfolder of a project folder the shim mounts the folder above that holds farmy.yml and runs farmy there" do
    folder_named "notes"
    above_holds "farmy.yml"

    shim "status"

    assert_mounted_at_own_path "farmy", the_folder_above
    assert_farmy_ran_in "status", the_folder_above
  end

  test "-C through the shim mounts the named folder and runs farmy there" do
    home_folders "~/containers"

    shim "-C", machine_path("~/containers"), "status"

    assert_mounted_at_own_path "farmy", "~/containers"
    assert_farmy_ran_in "status", "~/containers"
  end

  test "the shim hands farmy in the control container the folder it resolved, the XDG folders and the host's home" do
    shim "status"

    assert_handed_to_farmy "status", "FARMY_DIR" => "~/.config/farmy", "XDG_CONFIG_HOME" => "~/.config",
                                     "XDG_STATE_HOME" => "~/.local/state", "FARMY_HOST_HOME" => home
  end

  test "the shim passes the host's Git identity to every command, not only init" do
    host_git_identity "Dana Brooks", "dana@example.com"

    shim "status"

    assert_handed_to_farmy "status", "GIT_USER_NAME" => "Dana Brooks", "GIT_USER_EMAIL" => "dana@example.com"
  end

  # Record 2026-10-29-1105: what a real host shows and the fake docker did not.

  test "the shim tidies the paths it resolves: an XDG_CONFIG_HOME with a trailing slash still mounts and hands over ~/.config/farmy and ~/.config" do
    shim "status", env: { "XDG_CONFIG_HOME" => machine_path("~/.config") + "/" }

    assert_mounted_at_own_path "farmy", "~/.config/farmy"
    assert_handed_to_farmy "status", "FARMY_DIR" => "~/.config/farmy", "XDG_CONFIG_HOME" => "~/.config"
  end

  test "with HOME unset and no folder named, the shim refuses, names HOME, and starts no control container" do
    home_is_unset

    shim "status"

    assert_exit 1
    assert_stderr "HOME"
    refute_container "farmy"
  end

  test "when the folder in use lies inside a Git repository on the host, the shim hands farmy that repository's top folder as FARMY_HOST_GIT_TOP" do
    home_is_a_repository "~/.config" # inside the control container its .git is not mounted, so farmy cannot see it

    shim "status"

    assert_handed_to_farmy "status", "FARMY_HOST_GIT_TOP" => "~/.config"
  end

  test "outside any Git repository the shim hands farmy no FARMY_HOST_GIT_TOP" do
    shim "status"

    refute_handed_to_farmy "status", "FARMY_HOST_GIT_TOP"
  end

  test "on a Mac without the developer tools the shim runs no git, so macOS never offers to install them, and passes no Git identity" do
    macos_host
    mac_developer_tools installed: false
    host_git_identity "Dana Brooks", "dana@example.com"
    record_git_runs

    shim "status"

    refute_git_run
    refute_handed_to_farmy "status", "GIT_USER_NAME", "GIT_USER_EMAIL"
  end

  test "on a Mac with the developer tools the shim passes the host's Git identity" do
    macos_host
    mac_developer_tools installed: true
    host_git_identity "Dana Brooks", "dana@example.com"

    shim "status"

    assert_handed_to_farmy "status", "GIT_USER_NAME" => "Dana Brooks", "GIT_USER_EMAIL" => "dana@example.com"
  end

  test "the commands the shim runs on the host see XDG_CONFIG_HOME and XDG_STATE_HOME as the user left them: an unlock command sees neither set" do
    home_holds "~/.config/farmy/farmy.yml" => fixture("farmy/keys-unlock.yml") # secrets.unlock: [INFISICAL_TOKEN]
    unlock_command ': "$1"; printf "%s %s\n" "${XDG_CONFIG_HOME-unset}" "${XDG_STATE_HOME-unset}" > "$HOME/xdg-seen"; echo st.d41d8cd9'

    shim "start", "shop"

    assert_machine_file "~/xdg-seen", includes: "unset unset"
  end
end
