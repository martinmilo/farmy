class DotfilesTest < AcceptanceTest
  def setup = dotfiles_workspace # a real local bare repository and app homes with the image's default shell files

  test "a private HTTPS dotfiles clone uses the loaded token broker route without exposing its token" do
    private_dotfiles :token

    farmy "start", "shop"

    assert_success
    assert_dotfiles_authentication :token
    refute_env "shop", "GIT_TOKEN"
  end

  test "a private SSH dotfiles clone uses the broker's SSH route without placing a private key in the app" do
    private_dotfiles :ssh

    farmy "start", "shop"

    assert_success
    assert_dotfiles_authentication :ssh
    refute_env "shop", "GIT_SSH_KEY"
    refute_home_path "shop", ".ssh/id_ed25519"
  end

  test "a second app reuses the complete single shared dotfiles clone" do
    farmy "start", "shop", "notes"

    assert_success
    assert_shared_dotfiles_clone
    assert_dotfile_link "shop", ".zshrc"
    assert_dotfile_link "notes", ".zshrc"
  end

  test "the first dotfiles clone follows a trunk default branch when the remote has no main branch" do
    dotfiles_default_branch "trunk"

    farmy "start", "shop"

    assert_success
    assert_shared_dotfiles_clone
    assert_dotfiles_branch "trunk"
    assert_default_dotfile_links "shop"
  end

  test "simultaneous app starts expose exactly one complete usable dotfiles clone" do
    start_apps_concurrently "shop", "notes"

    assert_success
    assert_shared_dotfiles_clone
    assert_dotfile_link "shop", ".zshrc"
    assert_dotfile_link "notes", ".zshrc"
  end

  test "without an installer farmy links dotted files and merges dotted directories while excluding repository metadata" do
    app_home_file "shop", ".config/private-app/config", "keep private settings\n"

    farmy "start", "shop"

    assert_success
    assert_default_dotfile_links "shop"
    assert_home_file "shop", ".config/private-app/config", content: "keep private settings\n"
  end

  test "the image's default bashrc zshrc and profile are backed up once then replaced by repository links" do
    farmy "start", "shop"

    assert_success
    assert_dotfile_backups "shop"
    assert_dotfile_link "shop", ".bashrc"
    assert_dotfile_link "shop", ".zshrc"
    assert_backup_reported_once
  end

  test "a personal shell configuration is backed up with its original bytes before dotfiles replace it" do
    app_home_file "shop", ".zshrc", "export PERSONAL_EDITOR=nvim\n"

    farmy "start", "shop"

    assert_success
    assert_dotfile_backups "shop", originals: { ".zshrc" => "export PERSONAL_EDITOR=nvim\n" }
    assert_dotfile_link "shop", ".zshrc"
    assert_backup_reported_once
  end

  test "an actual restart reapplies fallback dotfile links without another backup or backup report" do
    farmy "start", "shop"

    farmy "restart", "shop"

    assert_success
    assert_dotfile_backups "shop"
    assert_default_dotfile_links "shop"
    refute_stdout ".dotfiles-backup"
    refute_stderr ".dotfiles-backup"
  end

  test "an unmergeable directory where the repository has a dotfile is refused without deleting its data" do
    app_home_file "shop", ".zshrc/local-note", "Keep this private directory.\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr(/\.zshrc.*(?:directory|merge)|(?:directory|merge).*\.zshrc/im)
    assert_home_file "shop", ".zshrc/local-note", content: "Keep this private directory.\n"
  end

  test "dotfiles pull updates existing links and links newly added files in every running app" do
    farmy "start", "shop", "notes"
    advance_dotfiles

    farmy "dotfiles", "pull"

    assert_success
    assert_dotfile_link "shop", ".zshrc", content: "export FARMY_DOTFILES_ZSH=updated\n"
    assert_dotfile_link "notes", ".inputrc", content: "set editing-mode vi\n"
  end

  test "an app started after dotfiles pull uses the updated shared checkout" do
    farmy "start", "shop"
    advance_dotfiles
    farmy "dotfiles", "pull"

    farmy "start", "notes"

    assert_success
    assert_dotfile_link "notes", ".inputrc", content: "set editing-mode vi\n"
    assert_shared_dotfiles_clone
  end

  test "apps receive the dotfiles clone read-only and cannot modify a tracked dotfile" do
    farmy "start", "shop"
    assert_dotfiles_readonly "shop"

    farmy "run", "shop", "sh", "-c", "printf tampered > \"$HOME/.zshrc\""

    assert_failure
    assert_stderr(/read.only|permission denied/i)
    assert_dotfile_link "shop", ".zshrc", content: "export FARMY_DOTFILES_ZSH=applied\n"
  end

  test "a failed dotfiles clone names the operation and stops service startup without an applied revision" do
    configure_toolbox dotfiles: { "repo" => "file:///does-not-exist/dotfiles.git" }

    farmy "start", "shop"

    assert_exit 1
    assert_stderr(/dotfiles.*(?:clone|repository)|(?:clone|repository).*dotfiles/im)
    refute_home_path "shop", ".dotfiles-installations"
  end

  test "destroying a service preserves the dotfiles checkout and another service's tool data" do
    farmy "start", "shop", "notes"
    app_home_file "notes", ".local/share/nvim/treesitter-parser.so", "compiled once\n"

    farmy "destroy", "shop", stdin: "y\n"

    assert_success
    assert_shared_dotfiles_clone
    assert_home_file "notes", ".local/share/nvim/treesitter-parser.so", content: "compiled once\n"
  end
end
