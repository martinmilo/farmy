class DistributionTest < AcceptanceTest
  def setup = workspace("workshop")

  test "the distribution exposes its single version source as VERSION" do
    assert_equal SHIPPED, work_file("VERSION").strip
  end

  test "farmy --version names the shipped version with a build hash" do
    farmy "--version"

    assert_success
    assert_stdout(/\Afarmy #{Regexp.escape(SHIPPED)} \([0-9a-f]{8,}\)\s*\z/)
  end

  test "farmy-built service and gate images carry version and hash labels" do
    egress_apps

    farmy "start", "shop"

    assert_success
    assert_image_release_labels
  end

  test "a locally built control image carries version and hash labels" do
    shim "init"

    assert_success
    assert_image_release_labels
  end

  test "a published control is pulled first and reports the pull without a local build" do
    published_release

    distribution_shim "init"

    assert_success
    assert_pulled "registry.example.com/acme/farmy-control:#{SHIPPED}"
    refute_control_build
    assert_stderr(/pull/i)
  end

  test "a failed control pull reports its failure and builds from the available checkout" do
    fail_pull "control", SHIPPED

    distribution_shim "init"

    assert_success
    assert_local_control_built
    assert_stderr(/pull.*fail|fail.*pull/i)
    assert_stderr(/build/i)
  end

  test "FARMY_BUILD equals 1 builds control locally without a control pull" do
    published_release

    distribution_shim "init", env: { "FARMY_BUILD" => "1" }

    assert_success
    refute_control_pull
    assert_local_control_built
    assert_stderr(/build/i)
  end

  test "published helper images are pulled while only the service toolbox needs a local build" do
    egress_apps
    published_release

    distribution_farmy "start", "shop"

    assert_success
    assert_pulled "registry.example.com/acme/farmy-keys:#{SHIPPED}", "registry.example.com/acme/farmy-knowledge:#{SHIPPED}", "registry.example.com/acme/farmy-gate:#{SHIPPED}"
  end

  test "an exact matching folder pin permits normal commands" do
    write_file "farmy.yml", "farmy: #{SHIPPED}\n"

    farmy "status"

    assert_success
  end

  test "a mismatched folder pin refuses the binary before any service starts and names the fix" do
    write_file "farmy.yml", "farmy: 0.3.0\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "farmy update --to 0.3.0"
    refute_container "shop"
  end

  test "a quoted folder pin mismatch is refused by the shim before control starts" do
    write_file "farmy.yml", "farmy: '0.3.0' # the workspace release\n"
    published_release

    distribution_shim "init"

    assert_exit 1
    assert_stderr "farmy update --to 0.3.0"
    refute_container "farmy"
  end

  test "version remains available while the folder pin mismatches" do
    write_file "farmy.yml", "farmy: 0.3.0\n"

    farmy "--version"

    assert_success
    assert_stdout "farmy #{SHIPPED}"
  end

  test "a version range is refused with a reason rather than treated as an exact pin" do
    write_file "farmy.yml", "farmy: 0.x\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr(/exact|MAJOR.MINOR.PATCH|version/i)
    refute_container "shop"
  end

  test "status identifies an older toolbox and names the service rebuild command" do
    toolbox_built_by "0.0.9"

    farmy "status"

    assert_success
    assert_stdout "built by 0.0.9, now #{SHIPPED}: farmy rebuild shop"
  end

  test "JSON status exposes an older toolbox version and outdated flag for the TUI" do
    toolbox_built_by "0.0.9"

    farmy "status", "--json"

    assert_toolbox_metadata "0.0.9", outdated: true
  end

  [SHIPPED, "0.3.0"].each do |version|
    test "a toolbox built by #{version} is not marked older than the shipped #{SHIPPED}" do
      toolbox_built_by version

      farmy "status", "--json"

      assert_toolbox_metadata version, outdated: false
    end
  end

  test "a shim older than the running control image warns with both versions and update" do
    newer_running_control
    published_release

    distribution_shim "status"

    assert_stderr SHIPPED
    assert_stderr "0.3.0"
    assert_stderr "farmy update"
  end

  ["farmy.yml", "services/shop.yml"].each do |file|
    test "#{file} explicitly declaring format 1 is accepted" do
      formatted_file file, 1

      farmy "start", "shop"

      assert_success
    end

    test "#{file} format 2 refuses before start and names a published version that reads it" do
      formatted_file file, 2
      published_release "0.3.0", format: 2

      distribution_farmy "start", "shop"

      assert_exit 1
      assert_stderr file
      assert_stderr(/format.*2/i)
      assert_stderr "0.3.0"
      refute_container "shop"
    end

    test "#{file} future format with unavailable metadata reports an unknown reader and update" do
      formatted_file file, 7
      fail_pull "control", "latest"

      distribution_farmy "start", "shop"

      assert_exit 1
      assert_stderr file
      assert_stderr(/format.*7/i)
      assert_stderr(/unknown/i)
      assert_stderr "farmy update"
      refute_container "shop"
    end
  end

  test "both file kinds without a format continue to mean format 1" do
    farmy "start", "shop"

    assert_success
    assert_running "shop"
  end

  test "latest metadata that still cannot read the requested format does not invent a capable version" do
    formatted_file "farmy.yml", 7
    published_release "0.3.0", format: 1

    distribution_farmy "start", "shop"

    assert_exit 1
    assert_stderr(/unknown/i)
    assert_stderr "farmy update"
    refute_container "shop"
  end
end
