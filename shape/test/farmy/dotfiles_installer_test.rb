class DotfilesInstallerTest < AcceptanceTest
  def setup = dotfiles_workspace(install: true) # install.sh records its uid, real HOME, cwd and Git revision

  test "each app start invokes the repository installer as dev from its root after shared-data initialization" do
    farmy "start", "shop"

    assert_success
    assert_installer_applied "shop", count: 1
  end

  test "restarting an app runs its configured installer again even when the dotfiles revision is unchanged" do
    farmy "start", "shop"

    farmy "restart", "shop"

    assert_success
    assert_installer_applied "shop", count: 2
  end

  test "dotfiles pull reruns the executable installer as dev in every running app" do
    farmy "start", "shop", "notes"
    advance_dotfiles

    farmy "dotfiles", "pull"

    assert_success
    assert_installer_applied "shop", count: 2
    assert_installer_applied "notes", count: 2
  end

  test "status records the dotfiles revision that each container successfully applied" do
    farmy "start", "shop", "notes"

    farmy "status", "--json"

    assert_dotfiles_status "shop", state: "applied"
    assert_dotfiles_status "notes", state: "applied"
  end

  test "an installer failure stops that start with the container name and installer failure" do
    app_home_file "shop", "fail-dotfiles", "yes\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr(/shop.*(?:installer|install.sh)|(?:installer|install.sh).*shop/im)
    refute_home_path "shop", ".dotfiles-installations"
  end

  test "a pull with one failing installer reports partial application and still applies every other running container" do
    farmy "start", "shop", "notes"
    app_home_file "shop", "fail-dotfiles", "yes\n"
    advance_dotfiles

    farmy "dotfiles", "pull"

    assert_exit 1
    assert_pull_partial failed: "shop", applied: "notes"
    assert_installer_applied "notes", count: 2
  end

  test "a failed pull preserves the usable checkout and runs no installers" do
    farmy "start", "shop"
    dotfiles_upstream_unavailable

    farmy "dotfiles", "pull"

    assert_exit 1
    assert_stderr(/dotfiles.*(?:pull|fetch)|(?:pull|fetch).*dotfiles/im)
    assert_shared_dotfiles_clone
    assert_installer_applied "shop", count: 1
  end

  test "dotfiles pull refuses a dirty checkout and preserves its files revision and installer count" do
    farmy "start", "shop"
    dirty_dotfiles_checkout
    remember_dotfiles_checkout

    farmy "dotfiles", "pull"

    assert_exit 1
    assert_stderr(/dirty|uncommitted|local changes/i)
    assert_dotfiles_checkout_unchanged
    assert_installer_applied "shop", count: 1
    farmy "status", "--json"
    assert_dotfiles_applied_revision "shop"
  end

  test "dotfiles pull refuses non-fast-forward upstream history and preserves the checkout and applied revision" do
    farmy "start", "shop"
    rewrite_dotfiles_upstream
    remember_dotfiles_checkout

    farmy "dotfiles", "pull"

    assert_exit 1
    assert_stderr(/fast.forward|diverg|unrelated histor/i)
    assert_dotfiles_checkout_unchanged
    assert_installer_applied "shop", count: 1
    farmy "status", "--json"
    assert_dotfiles_applied_revision "shop"
  end

  test "dotfiles pull refuses a changed configured repository URL and preserves the existing clone and applied revision" do
    farmy "start", "shop"
    change_dotfiles_repository
    remember_dotfiles_checkout

    farmy "dotfiles", "pull"

    assert_exit 1
    assert_stderr(/(?:repo|url|origin).*(?:chang|differ|migrat)|(?:chang|differ|migrat).*(?:repo|url|origin)/im)
    assert_dotfiles_checkout_unchanged
    assert_installer_applied "shop", count: 1
    farmy "status", "--json"
    assert_dotfiles_applied_revision "shop"
  end

  test "after partial pull status retains the failed container's last applied revision and records the successful container's new revision" do
    farmy "start", "shop", "notes"
    app_home_file "shop", "fail-dotfiles", "yes\n"
    advance_dotfiles
    farmy "dotfiles", "pull"

    farmy "status", "--json"

    assert_dotfiles_status "shop", state: "failed", revision: :previous
    assert_dotfiles_status "notes", state: "applied"
  end
end
