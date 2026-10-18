# No app container ever has the shared dotfiles clone writable: its dotfiles, ~/.gitconfig among them,
# are links into the clone, so a writable clone lets anything in one container change every container's.
class DotfilesMountsTest < AcceptanceTest
  def setup = dotfiles_workspace # farmy.yml dotfiles: a file:// repository with .gitconfig, .zshrc, …

  test "an app created while dotfiles were not configured still gets the shared dotfiles clone read-only" do
    dotfiles_switched_off

    farmy "start", "shop"

    assert_success
    assert_dotfiles_readonly "shop"
  end

  test "an app created before dotfiles were configured has the clone read-only once they are, and dotfiles pull applies them there" do
    dotfiles_switched_off
    farmy "start", "shop"
    dotfiles_switched_on

    farmy "dotfiles", "pull"

    assert_dotfiles_readonly "shop"
    assert_dotfile_link "shop", ".zshrc", content: "export FARMY_DOTFILES_ZSH=applied\n"
  end

  test "dotfiles pull skips an app whose dotfiles submount is there but writable, naming farmy restart" do
    farmy "start", "shop", "notes"
    dotfiles_mount_made_writable "shop", submount: :writable
    advance_dotfiles

    farmy "dotfiles", "pull"

    assert_exit 1
    assert_stderr "farmy restart shop"
    refute_dotfiles_applied_in "shop"
    assert_shared_dotfiles_untouched
  end

  test "dotfiles pull skips an app whose shared dotfiles clone is still writable, naming farmy restart, and leaves the clone untouched" do
    farmy "start", "shop", "notes"
    dotfiles_mount_made_writable "shop"
    advance_dotfiles

    farmy "dotfiles", "pull"

    assert_exit 1
    assert_stderr "farmy restart shop"
    refute_dotfiles_applied_in "shop"
    assert_shared_dotfiles_untouched
    assert_dotfile_link "notes", ".inputrc", content: "set editing-mode vi\n"
  end
end
