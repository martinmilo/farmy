class ToolboxShellTest < AcceptanceTest
  def setup = dotfiles_workspace # .zshrc exports FARMY_DOTFILES_ZSH after home setup

  test "shell zsh configures dev's login shell and farmy ssh starts it as an interactive login shell" do
    configure_toolbox shell: "zsh"
    farmy "start", "shop"

    farmy "ssh", "shop"

    assert_success
    assert_login_shell "shop", "zsh"
    assert_dotfile_link "shop", ".zshrc"
  end

  test "an unknown login shell is refused by name before an app starts" do
    configure_toolbox shell: "missing-shell"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "missing-shell"
    assert_stderr(/shell/i)
    refute_container "shop"
  end
end
