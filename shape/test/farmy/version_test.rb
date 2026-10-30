class VersionTest < AcceptanceTest
  test "farmy --version and the TUI report the same version and commit" do
    farmy "--version"
    assert_success
    assert_reports_build SHIPPED
    cli = stdout

    farmy "tui", "--version"

    assert_success
    assert_equal cli, stdout
  end
end
