class ToolboxArchitectureIntegrationTest < AcceptanceTest
  def setup = real_toolbox_workspace # skips only when no real Docker daemon answers

  %w[arm64 amd64].each do |architecture|
    test "a real linux #{architecture} app image executes the catalogue's pinned nvim and rg versions under LANG=C.UTF-8" do
      select_tools "neovim", "ripgrep"
      farmy "start", "shop"

      build_and_run_real_toolbox "shop", architecture: architecture

      assert_success
      assert_real_tool_versions architecture: architecture
      assert_real_utf8_locale
    end
  end
end
