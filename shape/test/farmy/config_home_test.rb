# The default home's config folder is meant to be kept in git, like dotfiles: farmy writes a .gitignore when it
# sets the folder up, asks once on a terminal whether to keep it in git, and `farmy config git` does the same
# later; `farmy config path` prints the folder. Record 2026-10-29-0926.
class ConfigHomeTest < AcceptanceTest
  def setup = on_a_fresh_machine # HOME is the test's own; no ~/.config/farmy yet

  test "setting up the default home writes a .gitignore that keeps .env, a service's .env and .work out of git, and farmy.yml, definitions and tools.lock in" do
    farmy "add", "https://github.com/acme/shop.git", "--image", "ruby:3.4-slim"

    assert_success
    assert_git_ignores "~/.config/farmy", ".env", "services/shop.env", ".work/shop/compose.yml"
    refute_git_ignores "~/.config/farmy", "farmy.yml", "services/shop.yml", "tools.lock"
  end

  test "on a terminal, setting up the default home asks whether to keep it in git, and yes makes a repository whose first commit holds .gitignore and farmy.yml" do
    farmy_on_a_terminal "status", typing: "y"

    assert_success
    assert_asked "Keep ~/.config/farmy in git? [y/N]"
    assert_repository "~/.config/farmy", holding: %w[.gitignore farmy.yml]
  end

  test "answering no makes no repository, and the question is not asked again even when the folder is set up afresh" do
    farmy_on_a_terminal "status", typing: "n"
    assert_asked "Keep ~/.config/farmy in git? [y/N]"
    refute_repository "~/.config/farmy"
    home_loses "~/.config/farmy"

    farmy_on_a_terminal "status", typing: "y"

    assert_success
    refute_asked "in git?"
    refute_repository "~/.config/farmy"
  end

  test "without a terminal the default home is set up without a question and without a repository" do
    farmy "status"

    assert_success
    assert_machine_file "~/.config/farmy/farmy.yml"
    refute_asked "in git?"
    refute_repository "~/.config/farmy"
  end

  test "a default home that already has a farmy.yml, as a git clone brings it, is used as it is: nothing is asked and no .gitignore is added" do
    home_holds "~/.config/farmy/farmy.yml" => "format: 1\n",
               "~/.config/farmy/services/shop.yml" => "repo: https://github.com/acme/shop.git\nimage: ruby:3.4-slim\n"

    farmy_on_a_terminal "status", typing: "y"

    assert_success
    assert_stdout(/^shop\s+stopped\b/)
    refute_asked "in git?"
    refute_machine_path "~/.config/farmy/.gitignore"
  end

  test "after a no, farmy config git makes the repository: its first commit holds .gitignore, farmy.yml and the definitions, and never .env" do
    farmy_on_a_terminal "add", "https://github.com/acme/shop.git", "--image", "ruby:3.4-slim", typing: "n"
    home_holds "~/.config/farmy/.env" => "GIT_USER_NAME=Dana Brooks\nGIT_USER_EMAIL=dana@example.com\n",
               "~/.config/farmy/services/shop.env" => "RAILS_MASTER_KEY=4e7b1c90d2\n"

    farmy "config", "git"

    assert_success
    assert_repository "~/.config/farmy", holding: %w[.gitignore farmy.yml services/shop.yml]
  end

  test "farmy config git twice leaves one repository with one commit" do
    farmy "add", "https://github.com/acme/shop.git", "--image", "ruby:3.4-slim"
    farmy "config", "git"

    farmy "config", "git"

    assert_success
    assert_repository "~/.config/farmy", holding: %w[.gitignore farmy.yml services/shop.yml]
  end

  test "farmy config git in a folder already inside a Git repository makes none and names that repository" do
    home_is_a_repository "~/.config"

    farmy "config", "git"

    assert_success
    assert_stdout "in the Git repository ~/.config:"
    refute_repository "~/.config/farmy"
  end

  test "farmy config git makes no repository when FARMY_HOST_GIT_TOP names the repository the folder lies in, and names it" do
    farmy "config", "git", env: { "FARMY_HOST_GIT_TOP" => machine_path("~/.config") } # as the shim finds it on the host

    assert_success
    assert_stdout "in the Git repository ~/.config:"
    refute_repository "~/.config/farmy"
  end

  test "on a terminal, setting up the default home asks nothing and makes no repository when FARMY_HOST_GIT_TOP says the folder already lies in one" do
    farmy_on_a_terminal "status", typing: "y", env: { "FARMY_HOST_GIT_TOP" => machine_path("~/.config") }

    assert_success
    refute_asked "in git?"
    refute_repository "~/.config/farmy"
  end

  test "the .gitignore that set-up writes also keeps farmy's temporary files (.farmy.yml.4242.tmp, .tools.lock.4242.tmp) out of git" do
    farmy "status"

    assert_success
    assert_git_ignores "~/.config/farmy", ".farmy.yml.4242.tmp", ".tools.lock.4242.tmp"
  end

  test "farmy config path prints the folder in use" do
    farmy "config", "path"

    assert_success
    assert_prints_only "~/.config/farmy"
  end

  test "the usage shows -C <dir> and lists config path and config git" do
    farmy "help"

    assert_stdout "-C <dir>"
    assert_stdout(/^\s+config path\b/)
    assert_stdout(/^\s+config git\b/)
  end
end
