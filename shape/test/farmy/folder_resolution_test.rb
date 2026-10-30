# Which folder farmy uses, every command: -C <dir>, then FARMY_DIR, then the nearest folder holding a farmy.yml
# (the current one or a parent), then the default home. -C and FARMY_DIR name the folder itself, farmy.yml or
# not. Record 2026-10-29-0926.
class FolderResolutionTest < AcceptanceTest
  def setup = on_a_fresh_machine # HOME is the test's own; nothing tells farmy its folder unless the test does

  test "a farmy.yml in the current folder makes it the folder: start keeps .work beside it and no default home is created" do
    workspace "workshop"
    write_file "farmy.yml", "format: 1\n"

    farmy "start", "shop"

    assert_success
    assert_folder ".work"
    refute_machine_path "~/.config/farmy"
    refute_machine_path "~/.local/state/farmy"
  end

  test "from a subfolder, farmy uses the folder above that holds farmy.yml" do
    folder_named "notes"
    above_holds "farmy.yml"

    farmy "status"

    assert_success
    assert_status_folder the_folder_above
  end

  test "FARMY_DIR wins over a farmy.yml in the current folder" do
    write_file "farmy.yml", "format: 1\n"
    home_folders "~/containers"

    farmy "status", env: { "FARMY_DIR" => machine_path("~/containers") }

    assert_success
    assert_status_folder "~/containers"
  end

  test "-C wins over FARMY_DIR" do
    home_folders "~/containers", "~/work/containers"

    farmy "-C", machine_path("~/work/containers"), "status", env: { "FARMY_DIR" => machine_path("~/containers") }

    assert_success
    assert_status_folder "~/work/containers"
  end

  test "-C names a folder that has no farmy.yml, and farmy uses its definitions as they are" do
    workspace "workshop" # .env and three definitions, no farmy.yml

    farmy "-C", ".", "status"

    assert_success
    assert_status_folder dir
    assert_stdout(/^shop\s+stopped\b/)
  end

  test "-C naming a folder that does not exist is a mistake in the command line, naming it, and nothing is created" do
    farmy "-C", machine_path("~/containers"), "status"

    assert_exit 2
    assert_stderr "~/containers"
    refute_machine_path "~/containers"
    refute_machine_path "~/.config/farmy"
  end

  test "FARMY_DIR naming a folder that does not exist is refused, naming FARMY_DIR, and nothing is created" do
    farmy "status", env: { "FARMY_DIR" => machine_path("~/containers") }

    assert_exit 1
    assert_stderr "FARMY_DIR"
    assert_stderr "~/containers"
    refute_machine_path "~/containers"
    refute_machine_path "~/.config/farmy"
  end

  test "a current folder with services/ and .env but no farmy.yml is left as it is, and farmy says it uses ~/.config/farmy and how to keep this folder" do
    workspace "workshop" # an old containers folder: .env and services/, no farmy.yml

    farmy "status"

    assert_success
    assert_stderr "~/.config/farmy"
    assert_stderr "touch farmy.yml"
    assert_stderr "farmy -C ."
    assert_nothing_written
  end

  test "an unknown service is refused naming the folder farmy looked in" do
    workspace "workshop"
    write_file "farmy.yml", "format: 1\n"

    farmy "start", "crm"

    assert_exit 2
    assert_stderr "unknown service 'crm'"
    assert_stderr dir
  end

  test "farmy -C . init in a plain folder writes a farmy.yml there, so the next command run there finds that folder" do
    host_git_identity "Dana Brooks", "dana@example.com"
    farmy "-C", ".", "init"
    assert_success
    assert_file "farmy.yml"

    farmy "status"

    assert_status_folder dir
  end
end
