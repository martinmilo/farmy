class AddTest < AcceptanceTest
  def setup = settings # a folder with .env and nothing else

  test "add writes a definition named after the repository with its URL and image, and says how to start it" do
    farmy "add", "https://github.com/acme/shop.git", "--image", "ruby:3.4-slim"

    assert_success
    assert_file "services/shop.yml", includes: "repo: https://github.com/acme/shop.git"
    assert_file "services/shop.yml", includes: "image: ruby:3.4-slim"
    assert_written_only "services/shop.yml"
    assert_stdout "farmy start shop"
  end

  test "add --name writes the definition under that name" do
    farmy "add", "https://codeberg.org/acme/notes.git", "--image", "node:22-bookworm-slim", "--name", "frontend"

    assert_success
    assert_file "services/frontend.yml", includes: "repo: https://codeberg.org/acme/notes.git"
    assert_stdout "farmy start frontend"
  end

  test "add without --image and without a terminal is a mistake in the command line" do
    farmy "add", "https://github.com/acme/shop.git"

    assert_exit 2
    assert_stderr "--image"
    assert_nothing_written
  end

  test "add for a service that is defined already is refused by file name and the file is kept" do
    workspace "workshop"

    farmy "add", "https://github.com/acme/shop.git", "--image", "ruby:3.4-slim"

    assert_exit 1
    assert_stderr "services/shop.yml"
    assert_unchanged "services/shop.yml"
  end

  test "add without a URL is a mistake in the command line" do
    farmy "add"

    assert_exit 2
    assert_stderr "add"
    assert_nothing_written
  end
  test "add refuses a repository that is not a clone URL as a mistake in the command line, naming it" do
    farmy "add", "<owner>/<repo>", "--image", "ruby:3.4-slim"

    assert_exit 2
    assert_stderr "<owner>/<repo>"
    assert_stderr "clone URL"
    assert_nothing_written
  end

  test "add says the image will carry no agent without agents: in farmy.yml" do
    farmy "add", "https://github.com/acme/billing.git", "--image", "ruby:3.4-slim"

    assert_success
    assert_stdout "agents: none"
  end

  test "add names the agents the image will carry, with their modes" do
    write_file "farmy.yml", "agents:\n  claude:\n    mode: api-key\n  codex: {}\n"

    farmy "add", "https://github.com/acme/billing.git", "--image", "ruby:3.4-slim"

    assert_stdout(/agents: claude \(api-key\), codex \(subscription\)/)
  end
end
