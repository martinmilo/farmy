# On Linux farmy writes the user's files as the user (record 2026-10-29-1215). The shim runs every farmy command in
# the control container as the invoking user, the session included, so what farmy writes in the folder and the state
# folder is theirs from the moment it is written, with no chown afterwards. Where root in a container is already the
# user on the host (a rootless daemon, a user-namespace remap, a Mac's file sharing), farmy runs as root as before.
class HostUserTest < AcceptanceTest
  def setup = on_a_fresh_machine # HOME is the test's own; the default home is made by the commands below

  test "on Linux the shim runs every farmy command in the control container as the invoking user: docker exec -u <uid>:<gid>" do
    shim "status"

    assert_success
    assert_farmy_ran_as_the_invoking_user
  end

  test "a first bare farmy on a terminal runs the session as the invoking user, so what it writes in ~/.config/farmy and the state folder is the user's from the start" do
    shim_on_a_terminal # no command: the session

    assert_farmy_ran_as_the_invoking_user
  end

  test "with a rootless Docker daemon the shim runs farmy in the control container as root, which is the invoking user on the host" do
    docker_daemon_is "rootless"

    shim "status"

    assert_success
    assert_farmy_ran_as_root
  end

  test "with a Docker daemon that remaps users (userns-remap) the shim runs farmy in the control container as root, as before: there neither root nor the user's uid in a container is the user on the host" do
    docker_daemon_is "userns"

    shim "status"

    assert_success
    assert_farmy_ran_as_root
  end

  test "on a Mac the shim runs farmy in the control container as root, as before: the Mac's file sharing gives what it writes to the user" do
    macos_host

    shim "status"

    assert_success
    assert_farmy_ran_as_root
  end
  # ── who it runs as stays put (record 2026-10-29-1530) ──

  test "once the control container is made for the invoking user, a docker info that fails does not change who farmy runs as: the container is kept and farmy runs as that user" do
    control_container_up
    docker_info_fails

    shim "status"

    assert_success
    assert_control_container_kept
    assert_farmy_ran_as_the_invoking_user
  end

  test "with a rootless daemon, once the control container is made to run farmy as root, a docker info that fails does not change that: the container is kept and farmy runs as root" do
    docker_daemon_is "rootless"
    control_container_up
    docker_info_fails

    shim "status"

    assert_success
    assert_control_container_kept
    assert_farmy_ran_as_root
  end

  test "a shell whose group changed (newgrp docker) is the same user: the control container made for that user is kept with its live session, and farmy runs as that uid" do
    control_container_up
    session_live
    the_shim_sees_the_caller uid: Process.uid, gid: (Process.gid == 999 ? 998 : 999), why: "the same user after `newgrp docker`: the same uid, another group"

    shim "status"

    assert_success
    assert_control_container_kept
    assert_session_still_live
    assert_farmy_ran_as_uid Process.uid
  end

  test "a root caller (sudo farmy) runs farmy as the owner of the containers folder, so what it writes there is that owner's, as 0.2.0 handed it to the folder owner" do
    the_shim_sees_the_caller uid: 0, gid: 0, why: "root (sudo farmy)"
    owner = File.stat(dir)

    shim "-C", dir, "status"

    assert_success
    assert_farmy_ran_as "#{owner.uid}:#{owner.gid}"
  end

  test "the home farmy runs with in the control container lies in a volume, so Docker logins, git's config and known hosts kept there outlive the control container, as /root in its volume did" do
    shim "status"

    assert_success
    assert_home_kept_in_a_volume
  end

  # ── sudo, and real-host risks (record 2026-10-29-1800) ──

  test "under sudo -E farmy runs in the default home as the user who ran sudo (SUDO_UID:SUDO_GID), even when ~/.config/farmy is root's by then, and the hand-back gives the default home back to that user" do
    home_folders "~/.config/farmy", "~/.local/state/farmy"
    the_host_says_root_owns "~/.config/farmy", "~/.local/state/farmy" # as an earlier sudo -E farmy left them
    the_shim_runs_under_sudo_e

    shim "status"

    assert_success
    assert_farmy_ran_as_the_invoking_user
    assert_handed_back "~/.config/farmy", "~/.local/state/farmy"
  end

  test "a control container made to run farmy as root for a root caller is not used for a plain user's commands: with no live run it is made anew for that user" do
    workspace "workshop"
    control_container_made_for_root_by_a_root_caller

    shim "status"

    assert_success
    assert_control_container_made_anew_for_this_folder
    assert_farmy_ran_as_the_invoking_user
  end

  test "with a docker client that warns on stderr at every call, a stopped control container serving another folder, with no run live in it, is replaced by one for this folder" do
    workspace "workshop"
    control_container_for_another_folder
    control_container_stopped
    docker_client_warns

    shim "-C", dir, "status"

    assert_success
    assert_control_container_made_anew_for_this_folder
  end

  test "with a docker client that warns on stderr at every call, a running control container made for the invoking user is kept and farmy runs in it as that user" do
    control_container_up
    docker_client_warns

    shim "status"

    assert_success
    assert_control_container_kept
    assert_farmy_ran_as_the_invoking_user
  end

  (1..6).each do |nth|
    test "when inspect number #{nth} of a command's reads of the control container fails, farmy runs as the user the container was made for, or the command is refused naming the error; the container is kept with its live session" do
      control_container_up
      session_live
      any_one_inspect_fails nth

      shim "status"

      assert_control_container_kept
      assert_session_still_live
      assert_ran_as_the_invoking_user_or_refused_naming_the_error
    end
  end

  test "in a containers folder another user owns (a shared folder), the one-time hand-back hands over nothing in it" do
    workspace "workshop"
    write_file "farmy.yml", "format: 1\n"
    the_shim_sees_the_caller uid: 4242, gid: 4242, why: "dana (4242), who does not own this folder: it is shared, and another user's"

    shim "status"

    assert_success
    assert_hand_back_names_nothing_in dir
  end

  test "in a containers folder of the user's own, the one-time hand-back covers only farmy's state in .work: never the folder itself, farmy.yml, services/ or .env" do
    workspace "workshop"
    write_file "farmy.yml", "format: 1\n"

    shim "status"

    assert_success
    assert_hand_back_names_nothing_in dir, but: ".work"
  end
end
