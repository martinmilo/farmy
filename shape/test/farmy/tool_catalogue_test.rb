class ToolCatalogueTest < AcceptanceTest
  def setup = toolbox_workspace # three independent Debian workbenches, no selected tools

  test "the shipped catalogue names neovim ripgrep fd fzf bat lazygit delta jq with official amd64 and arm64 release pins and ripgrep at least 15.2" do
    farmy "toolbox", "list", "--json"

    assert_success
    assert_tool_catalogue
  end

  %w[amd64 arm64].each do |architecture|
    test "every selected shipped tool has a pinned #{architecture} download and checksum in the toolbox Dockerfile without distro tool packages" do
      select_tools "neovim", "ripgrep", "fd", "fzf", "bat", "lazygit", "delta", "jq"

      farmy "start", "shop"

      assert_success
      assert_tool_downloads "shop", architecture: architecture
    end
  end

  test "a custom tool installs its verified arm64 musl artifact through the same catalogue fields as shipped tools" do
    counter_catalogue
    farmy "start", "shop"

    install_captured_toolbox "shop", architecture: "arm64", family: "apk"

    assert_success
    assert_installed_counter version: "1.0.0", platform: "linux-arm64-musl"
  end

  test "a custom tool installs its verified amd64 glibc artifact on the apt base family" do
    counter_catalogue
    farmy "start", "shop"

    install_captured_toolbox "shop"

    assert_success
    assert_installed_counter version: "1.0.0", platform: "linux-amd64-glibc"
  end

  test "a failed tool checksum names counter and its artifact and stops before installation" do
    counter_catalogue bad_checksum: true
    farmy "start", "shop"

    install_captured_toolbox "shop"

    assert_failure
    assert_stderr(/counter.*(?:checksum|sha256)|(?:checksum|sha256).*counter/i)
    assert_stderr "linux-amd64-glibc"
    refute_installed_counter
  end

  test "workspace tools reach every image and a service adds only its own selected tools" do
    select_tools "ripgrep"
    select_tools "neovim", "ripgrep", service: "shop"

    farmy "start", "shop", "notes"

    assert_tools_selected "shop", "neovim", "ripgrep"
    assert_tools_selected "notes", "ripgrep"
  end

  test "omitting tools selects none even though the shipped catalogue is available" do
    farmy "start", "shop"

    assert_success
    assert_tools_selected "shop"
  end

  test "an unknown selected tool is refused by name before an app is made" do
    select_tools "missing-editor"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "missing-editor"
    assert_stderr(/unknown|catalogue/i)
    refute_container "shop"
  end

  test "a selected custom tool missing an arm64 glibc artifact is refused with its platform before building" do
    counter_catalogue missing: "linux-arm64-glibc"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "counter"
    assert_stderr "linux-arm64-glibc"
    refute_container "shop"
  end

  test "changing a shipped version without a complete replacement artifact set never inherits the old version's pins" do
    configure_toolbox tools: ["ripgrep"], tool_catalogue: { "ripgrep" => { "version" => "99.0.0" } }

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "ripgrep"
    assert_stderr(/artifact|checksum/i)
    refute_container "shop"
  end

  test "a stale lock cannot repair an incomplete explicit version override by reusing inherited artifacts" do
    configure_toolbox tools: ["ripgrep"], tool_catalogue: { "ripgrep" => { "version" => "99.0.0" } }
    stale_ripgrep_lock

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "ripgrep"
    assert_stderr(/artifact|checksum/i)
    assert_unchanged "tools.lock"
    refute_container "shop"
  end

  test "a new ripgrep version with only one replacement artifact is refused instead of inheriting the other architecture and libc pins" do
    ripgrep_version_override complete: false

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "ripgrep"
    assert_stderr(/artifact|linux-arm64|linux-amd64-musl/i)
    refute_container "shop"
  end

  test "a new ripgrep version with a complete replacement artifact matrix uses every replacement pin" do
    ripgrep_version_override complete: true

    farmy "start", "shop"

    assert_success
    assert_tool_pin "shop", "ripgrep", version: "99.0.0", platform: "linux-amd64-glibc", checksum: "f5dc45b7d71fff5da9e8bc92314e3e4ea01d42e0e5de90b7ece9feeba39c8f1d"
    assert_tool_pin "shop", "ripgrep", version: "99.0.0", platform: "linux-arm64-glibc", checksum: "233db563f89de62d81d6838a7fa24d9ea9eae6570bbd9bdf4de464d48ba281c7"
    assert_tool_pin "shop", "ripgrep", version: "99.0.0", platform: "linux-amd64-musl", checksum: "19ce30bedeaa392dcf85a58e426db384a18e66f7a048268c23fabf35702bcd4c"
    assert_tool_pin "shop", "ripgrep", version: "99.0.0", platform: "linux-arm64-musl", checksum: "ab83b69af5ce56da582975a0ce91c4e69e55a242ed0d695ebb93b6c49f5127f2"
  end

  test "a custom toolbox receives the managed tool layer after its own Dockerfile" do
    counter_catalogue
    write_file "toolbox/Dockerfile", "ARG BASE\nFROM ${BASE}\nRUN mkdir -p /opt/team-environment\n"

    farmy "start", "shop"

    assert_success
    assert_built dockerfile_includes: "/opt/team-environment"
    assert_tools_selected "shop", "counter"
    assert_managed_toolbox_consumes_installer "shop"

    install_captured_toolbox "shop"
    assert_success
    assert_installed_counter version: "1.0.0", platform: "linux-amd64-glibc"
  end

  test "a custom toolbox can opt out of managed tools and packages" do
    counter_catalogue
    configure_toolbox packages: ["libvips"], toolbox: { "managed" => false }
    write_file "toolbox/Dockerfile", "ARG BASE\nFROM ${BASE}\nRUN mkdir -p /opt/team-environment\n"

    farmy "start", "shop"

    assert_success
    assert_built dockerfile_includes: "/opt/team-environment"

    exercise_captured_toolbox_installer "shop"

    assert_success
    assert_unmanaged_toolbox "shop", packages: ["libvips"]
  end

  test "global distro packages reach every toolbox and service packages reach only their service" do
    select_tools packages: ["libvips", "imagemagick"]
    select_tools service: "shop", packages: ["postgresql-client"]

    farmy "start", "shop", "notes"

    assert_packages_selected "shop", "libvips", "imagemagick", "postgresql-client"
    assert_packages_selected "notes", "libvips", "imagemagick"
    assert_package_installation "shop", family: "apt"
  end

  test "Alpine installs explicit package names with apk in its toolbox layer" do
    write_file "services/shop.yml", "repo: none\nimage: alpine:3.21\npackages: [vips, postgresql-client]\n"

    farmy "start", "shop"

    assert_success
    assert_packages_selected "shop", "vips", "postgresql-client"
    assert_package_installation "shop", family: "apk"
  end
end
