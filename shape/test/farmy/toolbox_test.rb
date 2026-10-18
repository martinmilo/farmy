class ToolboxTest < AcceptanceTest
  def setup = workspace("workshop") # shop: image ruby:3.4

  test "the app image is built from the service's image with farmy's toolbox Dockerfile" do
    write_file "farmy.yml", "agents:\n  claude: {}\n"

    farmy "start", "shop"

    assert_built with_arg: "BASE=ruby:3.4"
    assert_built with_arg: "AGENTS=claude"
  end

  test "a toolbox folder in the containers folder is built instead of farmy's" do
    write_file "toolbox/Dockerfile", "ARG BASE\nFROM ${BASE}\nRUN apk add --no-cache git zsh\n"

    farmy "start", "shop"

    assert_built with_arg: "BASE=ruby:3.4", dockerfile_includes: "RUN apk add --no-cache git zsh"
  end

  test "an Alpine image is accepted by farmy" do # that the toolbox builds on it: integration_test.rb
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4-alpine\n"

    farmy "start", "shop"

    assert_success
    assert_running "shop"
    assert_built with_arg: "BASE=ruby:3.4-alpine"
  end

  test "with no agent at all the toolbox installs none and the service has no agents volume" do
    write_file "farmy.yml", "agents: []\n"

    farmy "start", "shop"

    assert_built with_arg: "AGENTS="
    refute_mounted "shop", "shop-agents"
  end

  test "with the knowledge container switched off nothing shared starts" do
    write_file "farmy.yml", "knowledge: false\n"

    farmy "start", "shop"

    assert_running "shop"
    refute_container "farmy-knowledge"
  end
  test "the toolbox Dockerfile gives BASE a default, so BuildKit does not warn about it" do
    farmy "start", "shop"

    assert_built with_arg: "BASE=ruby:3.4", dockerfile_includes: "ARG BASE=debian:bookworm-slim"
  end

  test "every app image runs with LANG=C.UTF-8, set in farmy's toolbox layer" do
    farmy "start", "shop"

    assert_toolbox_image_env "shop", "LANG", "C.UTF-8"
  end

  test "the toolbox installs an SSH client, openssh-client, for git over SSH" do
    farmy "start", "shop"

    assert_toolbox_installs "shop", "openssh-client"
  end
end
