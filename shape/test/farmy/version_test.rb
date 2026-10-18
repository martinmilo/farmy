class VersionTest < AcceptanceTest
  test "farmy --version and the TUI report the same build hash" do
    farmy "--version"
    assert_success
    assert_stdout(/\Afarmy \S+ \([0-9a-f]{8,}\)\s*\z/)
    cli = stdout

    farmy "tui", "--version"

    assert_success
    assert_equal cli, stdout
  end
end
