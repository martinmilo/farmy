# The installer a GitHub release attaches (work/bin/render-release renders it): without --to it installs the
# release it came from; it ends by saying what it installed where, and how to put that folder on PATH.
class ReleaseInstallerTest < AcceptanceTest
  def setup = workspace("workshop")

  test "the release's installer, run without --to, installs the release it came from even when a newer one is latest" do
    published_release SHIPPED, latest: false
    published_release "0.2.0"

    install_from_release

    assert_success
    distribution_shim "--version"
    assert_stdout "farmy #{SHIPPED}"
  end

  test "the release's installer with --to installs that version" do
    published_release SHIPPED, latest: false
    published_release "0.2.0"

    install_from_release to: "0.2.0"

    assert_success
    distribution_shim "--version"
    assert_stdout "farmy 0.2.0"
  end

  test "the installer ends by naming the version and the folder, and the export line when the folder is not on PATH" do
    published_release

    install_from_release

    assert_success
    assert_stdout "farmy #{SHIPPED}"
    assert_stdout install_folder
    assert_stdout "export PATH=\"#{install_folder}:$PATH\""
  end

  test "on PATH, the installer prints no export line" do
    published_release

    install_from_release with_folder_on_path: true

    assert_success
    refute_stdout "export PATH="
  end
end
