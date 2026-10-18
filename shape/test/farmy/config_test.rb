class ConfigTest < AcceptanceTest
  def setup = workspace("workshop")

  test "an unknown key in farmy.yml is refused by name" do
    write_file "farmy.yml", "agent: [claude]\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "farmy.yml"
    assert_stderr "agent"
    refute_container "shop"
  end
end
