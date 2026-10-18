class SharedToolDataTest < AcceptanceTest
  def setup = dotfiles_workspace # default shared_data is [nvim], with private per-service homes

  test "two apps of the same platform libc and tool versions reuse only nvim share and cache directories" do
    app_platform "shop", architecture: "arm64", libc: "glibc"
    app_platform "notes", architecture: "arm64", libc: "glibc"

    farmy "start", "shop", "notes"

    assert_shared_tool_data "shop", other: "notes", platform: "linux-arm64-glibc"
  end

  test "an installed parser is reused by another app while unrelated local share and cache data remain private" do
    farmy "start", "shop", "notes"
    app_home_file "shop", ".local/share/nvim/parser.so", "compiled parser\n"
    app_home_file "shop", ".cache/nvim/editor-cache", "shared editor cache\n"
    app_home_file "shop", ".local/share/private-app/session", "private session\n"
    app_home_file "shop", ".cache/private-app/session", "private cache\n"

    farmy "start", "notes"

    assert_home_file "notes", ".local/share/nvim/parser.so", content: "compiled parser\n"
    assert_home_file "notes", ".cache/nvim/editor-cache", content: "shared editor cache\n"
    refute_home_path "notes", ".local/share/private-app/session"
    refute_home_path "notes", ".cache/private-app/session"
  end

  test "arm64 glibc arm64 musl and amd64 glibc never share compiled editor data" do
    app_platform "shop", architecture: "arm64", libc: "glibc"
    app_platform "notes", architecture: "arm64", libc: "musl"
    app_platform "toolkit", architecture: "amd64", libc: "glibc"

    farmy "start", "shop", "notes", "toolkit"

    assert_distinct_tool_data "shop", "notes", "toolkit"
  end

  test "different selected tool lists use different shared-data directories" do
    counter_catalogue
    select_tools "ripgrep", service: "notes"

    farmy "start", "shop", "notes"

    assert_distinct_tool_data "shop", "notes"
  end

  test "the same selected tools at a newer locked version use separate data without importing old parsers or cache" do
    counter_catalogue
    farmy "start", "shop"
    app_home_file "shop", ".local/share/nvim/parser.so", "built for counter 1.0.0\n"
    app_home_file "shop", ".cache/nvim/parser-cache", "cached for counter 1.0.0\n"
    write_counter_lock version: "2.0.0"

    farmy "start", "notes"

    assert_distinct_tool_data "shop", "notes"
    refute_home_path "notes", ".local/share/nvim/parser.so"
    refute_home_path "notes", ".cache/nvim/parser-cache"
    assert_home_file "shop", ".local/share/nvim/parser.so", content: "built for counter 1.0.0\n"
    assert_home_file "shop", ".cache/nvim/parser-cache", content: "cached for counter 1.0.0\n"
  end

  test "shared_data selects corresponding names under both local share and cache without sharing their parents" do
    configure_toolbox shared_data: ["nvim", "helix"]

    farmy "start", "shop", "notes"

    assert_named_shared_data "shop", "notes", "helix"
    assert_shared_tool_data "shop", other: "notes", platform: "linux-amd64-glibc"
  end

  test "existing private local share data is never automatically migrated into farmy-shared" do
    app_home_file "shop", ".local/share/nvim/private-parser.so", "keep this private\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr(/nvim.*(?:existing|migrat|conflict)|(?:existing|migrat|conflict).*nvim/im)
    assert_home_file "shop", ".local/share/nvim/private-parser.so", content: "keep this private\n"
    assert_private_data_not_migrated "private-parser.so"
  end

  test "private logins can share nvim data and read-only dotfiles without exposing shared login folders" do
    write_file "services/shop.yml", "repo: none\nimage: debian:bookworm-slim\nshared_logins: false\n"

    farmy "start", "shop", "notes"

    assert_success
    assert_shared_tool_data "shop", other: "notes", platform: "linux-amd64-glibc"
    assert_dotfiles_readonly "shop"
    assert_no_shared_logins "shop"
  end
end
