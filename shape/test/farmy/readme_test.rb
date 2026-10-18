# The repository's front page, held to the program: what farmy help lists is what the README names.
class ReadmeTest < AcceptanceTest
  test "the README at the root names every command the usage lists, and no command the usage does not" do
    farmy "help"

    assert_commands_documented_in root_file("README.md")
  end
end
