# Every app image runs farmy's own entrypoint, whatever toolbox it was built from, so a rebuild always
# gives an image that supports farmy's entrypoint modes; a custom toolbox's startup goes into toolbox/start.sh.
class FarmyEntrypointTest < AcceptanceTest
  def setup = dotfiles_workspace # shop, notes, toolkit: Debian workbenches; farmy.yml has dotfiles

  test "start with a toolbox folder in the containers folder says it builds that custom toolbox" do
    custom_toolbox

    farmy "start", "shop"

    assert_success
    assert_match(/custom toolbox.*toolbox|toolbox.*custom toolbox/i, stdout + stderr, "Expected start to say it builds the custom toolbox in the containers folder (naming the folder), never silently.#{transcript}")
  end

  test "a custom toolbox with an entrypoint from before modes still gets farmy's entrypoint, and dotfiles are applied" do
    custom_toolbox entrypoint: :before_modes

    farmy "start", "shop"

    assert_success
    refute_stderr "older farmy"
    assert_includes entrypoint_modes_label("shop"), "git-config"
    assert_dotfile_link "shop", ".zshrc", content: "export FARMY_DOTFILES_ZSH=applied\n"
  end

  test "after the older-image message, the farmy rebuild it names makes the next dotfiles pull apply there" do
    custom_toolbox entrypoint: :before_modes
    farmy "start", "shop"
    image_built_by_older_farmy "shop"
    advance_dotfiles
    farmy "dotfiles", "pull"
    assert_stderr "farmy rebuild shop"

    farmy "rebuild", "shop"
    farmy "dotfiles", "pull"

    assert_success
    refute_stderr "older farmy"
    assert_dotfile_link "shop", ".inputrc", content: "set editing-mode vi\n"
  end

  test "the modes label comes from the entrypoint installed in the image, not from a custom toolbox's claims" do
    custom_toolbox entrypoint: :claims_modes

    farmy "start", "shop"

    assert_success
    assert_includes entrypoint_modes_label("shop"), "git-config"
    refute_includes entrypoint_modes_label("shop"), "bogus"
  end

  test "a custom toolbox's start.sh is run as dev by farmy's entrypoint at container start" do
    custom_toolbox start_sh: "#!/bin/sh\nprintf '%s\\n' \"$(id -un)\" > \"$HOME/.toolbox-started\"\n"
    farmy "start", "shop"

    run_app_startup "shop"

    assert_success
    assert_equal "dev\n", app_home_file_content("shop", ".toolbox-started"), "Expected farmy's entrypoint to run the custom toolbox's start.sh as dev at container start, writing ~/.toolbox-started.#{transcript}"
  end
end
