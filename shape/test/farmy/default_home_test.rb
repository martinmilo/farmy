# A machine new to farmy: no folder is named and the current one has no farmy.yml, so farmy uses its default
# home: configuration in $XDG_CONFIG_HOME/farmy (~/.config/farmy), state in $XDG_STATE_HOME/farmy/.work
# (~/.local/state/farmy/.work). Record 2026-10-29-0926.
class DefaultHomeTest < AcceptanceTest
  def setup = on_a_fresh_machine # HOME is the test's own; nothing tells farmy its folder

  test "on a fresh machine add writes the definition into ~/.config/farmy/services and nothing into the current folder" do
    farmy "add", "https://github.com/acme/shop.git", "--image", "ruby:3.4-slim"

    assert_success
    assert_machine_file "~/.config/farmy/services/shop.yml", includes: "repo: https://github.com/acme/shop.git"
    assert_nothing_written
  end

  test "with XDG_CONFIG_HOME set, add writes the definition into $XDG_CONFIG_HOME/farmy/services" do
    farmy "add", "https://github.com/acme/shop.git", "--image", "ruby:3.4-slim", env: { "XDG_CONFIG_HOME" => machine_path("~/dotfiles/config") }

    assert_success
    assert_machine_file "~/dotfiles/config/farmy/services/shop.yml"
    refute_machine_path "~/.config/farmy"
  end

  test "an empty XDG_CONFIG_HOME counts as unset, so add writes into ~/.config/farmy" do
    farmy "add", "https://github.com/acme/shop.git", "--image", "ruby:3.4-slim", env: { "XDG_CONFIG_HOME" => "" }

    assert_success
    assert_machine_file "~/.config/farmy/services/shop.yml"
  end

  test "starting a service from the default home keeps farmy's state in ~/.local/state/farmy/.work and none in ~/.config/farmy" do
    workshop_in "~/.config/farmy"

    farmy "start", "shop"

    assert_success
    assert_machine_folder "~/.local/state/farmy/.work"
    refute_machine_path "~/.config/farmy/.work"
  end

  test "with XDG_STATE_HOME set, farmy's state goes to $XDG_STATE_HOME/farmy/.work" do
    workshop_in "~/.config/farmy"

    farmy "start", "shop", env: { "XDG_STATE_HOME" => machine_path("~/state") }

    assert_success
    assert_machine_folder "~/state/farmy/.work"
    refute_machine_path "~/.local/state/farmy"
  end

  test "inside the default home's config folder, farmy keeps its state in the state folder and never beside farmy.yml" do
    folder_named "farmy"
    config_home_is_the_folder_above
    workspace "workshop"
    write_file "farmy.yml", "format: 1\n"

    farmy "start", "shop"

    assert_success
    assert_machine_folder "~/.local/state/farmy/.work"
    refute_file ".work"
  end

  test "on a fresh machine status names ~/.config/farmy as the folder in use, with its state folder" do
    farmy "status"

    assert_success
    assert_status_folder "~/.config/farmy (state in ~/.local/state/farmy)"
  end

  test "status --json gives the folder in use and its state folder as absolute paths" do
    farmy "status", "--json"

    assert_success
    assert_json_folder path: "~/.config/farmy", state: "~/.local/state/farmy"
  end

  test "on a fresh machine status says: No services yet: farmy add <git url> [--image …]" do
    farmy "status"

    assert_success
    assert_stdout "No services yet: farmy add <git url> [--image …]"
  end

  test "starting a service when the default home defines none says that no services are defined yet in ~/.config/farmy" do
    home_holds "~/.config/farmy/.env" => "GIT_USER_NAME=Dana Brooks\nGIT_USER_EMAIL=dana@example.com\n"

    farmy "start", "shop"

    assert_exit 2
    assert_stderr "no services are defined yet"
    assert_stderr "~/.config/farmy"
  end

  test "on a fresh machine a service added with farmy add starts without farmy init, with the Git identity the shim passes" do
    farmy "add", "https://github.com/acme/shop.git", "--image", "ruby:3.4-slim"

    farmy "start", "shop", env: { "GIT_USER_NAME" => "Dana Brooks", "GIT_USER_EMAIL" => "dana@example.com" }

    assert_success
    assert_running "shop"
    assert_machine_file "~/.config/farmy/.env", includes: "GIT_USER_NAME=Dana Brooks"
  end

  test "with HOME unset and no XDG folders, farmy refuses to use a default home and names HOME" do
    home_is_unset

    farmy "status"

    assert_exit 1
    assert_stderr "HOME"
  end

  test "on a fresh machine init prepares the default home and names it" do
    host_git_identity "Dana Brooks", "dana@example.com"

    farmy "init"

    assert_success
    assert_machine_file "~/.config/farmy/.env", includes: "GIT_USER_NAME=Dana Brooks"
    assert_stdout "~/.config/farmy"
    assert_nothing_written
  end
end
