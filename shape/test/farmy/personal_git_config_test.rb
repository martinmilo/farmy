class PersonalGitConfigTest < AcceptanceTest
  test "entrypoint Git defaults are system scoped beside a read-only dotfiles linked personal gitconfig" do
    personal_git_dotfiles

    run_app_entrypoint

    assert_success
    assert_personal_gitconfig_preserved
    git_in_app "config", "--system", "--get", "user.name"
    assert_success
    assert_stdout "Container Default"
  end

  test "restarting entrypoint leaves the personal gitconfig link and repository bytes unchanged" do
    personal_git_dotfiles
    run_app_entrypoint
    assert_success

    run_app_entrypoint

    assert_success
    assert_personal_gitconfig_preserved
  end

  test "personal identity wins over farmy Git defaults with read-only dotfiles" do
    personal_git_dotfiles
    run_app_entrypoint
    assert_success

    git_in_app "config", "--get", "user.name"

    assert_success
    assert_stdout "Personal Developer"
  end

  test "ordinary personal Git preferences remain effective beside system defaults" do
    personal_git_dotfiles
    run_app_entrypoint
    assert_success

    git_in_app "config", "--get", "core.editor"

    assert_success
    assert_stdout "nvim"
  end

  { token: "http://keys:9181/dotfiles/acme/shop.git", ssh: "ssh://git@git.example.com/acme/shop.git" }.each do |transport, destination|
    test "managed #{transport} routing wins over a longer personal URL rewrite without changing gitconfig" do
      personal_git_dotfiles transport
      run_app_entrypoint
      assert_success

      git_route_probe "https://git.example.com/acme/shop.git"

      assert_success
      assert_stdout_is "#{destination}\n"
      assert_personal_gitconfig_preserved
    end
  end

  test "the managed SSH proxy remains effective despite a personal core sshCommand" do
    personal_git_dotfiles :ssh
    run_app_entrypoint
    assert_success

    git_in_app "config", "--get", "core.sshCommand"

    assert_success
    assert_stdout "nc -X connect -x proxy.example.com:8080"
    refute_stdout "personal-direct-route"
  end
end
