class UnknownToolboxVersionTest < AcceptanceTest
  def setup = workspace("workshop")

  test "an existing app image without farmy version says built by an unknown farmy and names rebuild" do
    toolbox_without_version

    farmy "status"

    assert_success
    assert_stdout "built by an unknown farmy: farmy rebuild shop"
  end

  test "JSON marks an existing unlabeled toolbox as outdated with a null version for the TUI" do
    toolbox_without_version

    farmy "status", "--json"

    assert_success
    assert_toolbox_metadata nil, outdated: true
  end

  test "a stopped app with an unlabeled image still reports its unknown farmy rebuild warning" do
    toolbox_without_version
    farmy "stop", "shop"

    farmy "status"

    assert_success
    assert_stdout "built by an unknown farmy: farmy rebuild shop"
  end

  test "a never built service does not report an existing image with unknown provenance" do
    farmy "status", "--json"

    assert_success
    assert_toolbox_metadata nil, outdated: false
  end
end
