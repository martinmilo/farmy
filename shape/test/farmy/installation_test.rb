class InstallationTest < AcceptanceTest
  def setup = workspace("workshop")

  test "installation into a temporary bin directory needs only Docker and POSIX tools and leaves one executable shim" do
    published_release

    install_distribution version: "0.1.0"

    assert_success
    assert_installed_only_shim
    assert_pulled "registry.example.com/acme/farmy-control:0.1.0"
  end

  test "installation without a version resolves the stable latest control label" do
    published_release "0.2.0"

    install_distribution

    assert_success
    assert_installed_only_shim
    distribution_shim "--version"
    assert_stdout "farmy 0.2.0"
  end

  test "an installed shim runs outside the checkout using its remembered registry" do
    installed_distribution

    distribution_shim "init", env: { "FARMY_REGISTRY" => "" }

    assert_success
    assert_running "farmy"
    refute_control_build
  end

  test "a standalone pull failure builds using a configured Docker source URL without a host clone" do
    installed_distribution
    fail_pull "control", "0.1.0"

    distribution_shim "init", env: { "FARMY_SOURCE" => "https://code.example.com/acme/farmy.git#v0.1.0:work" }

    assert_success
    assert_local_control_built source: "https://code.example.com/acme/farmy.git#v0.1.0:work"
    assert_stderr(/build/i)
  end

  test "a standalone failed pull without a source override builds the matching GitHub mirror tag work context" do
    installed_distribution
    fail_pull "control", "0.1.0"

    distribution_shim "init"

    assert_success
    assert_default_local_control_built
    assert_running "farmy"
  end

  test "an unpinned update pulls every newest release image and replaces the installed shim" do
    installed_distribution
    published_release "0.2.0"

    distribution_shim "update"

    assert_success
    assert_release_pulled "0.2.0"
    distribution_shim "--version"
    assert_stdout "farmy 0.2.0"
  end

  test "an explicit update target overrides latest and fixes an existing folder mismatch" do
    installed_distribution
    published_release "0.2.0", latest: false
    published_release "0.3.0"
    write_file "farmy.yml", "farmy: 0.2.0\n"

    distribution_shim "update", "--to", "0.2.0"

    assert_success
    assert_release_pulled "0.2.0"
    assert_unchanged "farmy.yml"
    distribution_shim "--version"
    assert_stdout "farmy 0.2.0"
  end

  test "update without a target respects an exact folder pin instead of latest" do
    installed_distribution
    published_release "0.2.0", latest: false
    published_release "0.3.0"
    write_file "farmy.yml", "farmy: 0.2.0\n"

    distribution_shim "update"

    assert_success
    assert_release_pulled "0.2.0"
    distribution_shim "--version"
    assert_stdout "farmy 0.2.0"
  end

  test "a failed helper-image update preserves the installed shim and all running containers" do
    installed_distribution
    distribution_shim "init"
    remember_container_starts
    remember_installed_shim
    published_release "0.2.0"
    fail_pull "gate", "0.2.0"

    distribution_shim "update"

    assert_failure
    assert_stderr "farmy-gate:0.2.0"
    assert_installed_shim_unchanged
    assert_no_container_restarted
  end

  test "a failed shim extraction preserves the installed executable" do
    installed_distribution
    remember_installed_shim
    published_release "0.2.0"
    missing_shim_artifact "0.2.0"

    distribution_shim "update"

    assert_failure
    assert_stderr(/farmy|shim|extract/i)
    assert_installed_shim_unchanged
  end
end
