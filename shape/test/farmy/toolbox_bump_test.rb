class ToolboxBumpTest < AcceptanceTest
  def setup = toolbox_workspace # counter release fixtures serve real bytes and published SHA-256 digests locally

  test "toolbox bump writes all architecture and libc pins to tools.lock and leaves farmy.yml byte-identical" do
    counter_catalogue

    farmy "toolbox", "bump"

    assert_success
    assert_locked_counter version: "2.0.0", arm64_musl: "d29ceabe164365f8efd2275f6ec57ea0a5cddeba334d52446b97e99563605446"
    assert_release_downloads "linux-amd64-glibc", "linux-arm64-glibc", "linux-amd64-musl", "linux-arm64-musl"
    assert_unchanged "farmy.yml"
  end

  test "toolbox bump with an explicit list updates the named tool even when it is inactive" do
    counter_catalogue selected: false

    farmy "toolbox", "bump", "counter"

    assert_success
    assert_locked_counter version: "2.0.0", arm64_musl: "d29ceabe164365f8efd2275f6ec57ea0a5cddeba334d52446b97e99563605446"
    assert_unchanged "farmy.yml"
  end

  test "toolbox bump with an explicit list preserves every field of an existing unselected tool lock entry" do
    two_counter_tools_with_lock
    remember_locked_tool "gauge"

    farmy "toolbox", "bump", "counter"

    assert_success
    assert_locked_counter version: "2.0.0", arm64_musl: "d29ceabe164365f8efd2275f6ec57ea0a5cddeba334d52446b97e99563605446"
    assert_locked_tool_unchanged "gauge"
    assert_unchanged "farmy.yml"
  end

  test "toolbox bump's default active selection includes tools selected only by a service" do
    counter_catalogue selected: false
    select_tools "counter", service: "notes"

    farmy "toolbox", "bump"

    assert_success
    assert_locked_counter version: "2.0.0", arm64_musl: "d29ceabe164365f8efd2275f6ec57ea0a5cddeba334d52446b97e99563605446"
  end

  test "one missing arm64 musl release aborts the entire bump and preserves tools.lock and farmy.yml" do
    counter_catalogue
    write_counter_lock
    counter_release_missing "linux-arm64-musl"

    farmy "toolbox", "bump"

    assert_exit 1
    assert_stderr(/counter.*linux-arm64-musl|linux-arm64-musl.*counter/m)
    assert_unchanged "tools.lock"
    assert_unchanged "farmy.yml"
  end

  test "a vendor checksum mismatch aborts bump without replacing the previous usable pins" do
    counter_catalogue
    write_counter_lock
    counter_release_corrupt "linux-arm64-musl"

    farmy "toolbox", "bump"

    assert_exit 1
    assert_stderr(/counter.*(?:checksum|sha256)|(?:checksum|sha256).*counter/im)
    assert_unchanged "tools.lock"
    assert_unchanged "farmy.yml"
  end

  test "one incomplete tool aborts a multi-tool bump even when another tool has a complete newer release" do
    two_counter_tools_with_lock
    counter_release_missing "linux-arm64-musl", tool: "gauge"

    farmy "toolbox", "bump", "counter", "gauge"

    assert_exit 1
    assert_stderr(/gauge.*linux-arm64-musl|linux-arm64-musl.*gauge/m)
    assert_unchanged "tools.lock"
    assert_unchanged "farmy.yml"
  end

  test "normal builds use a tools.lock override without changing either configuration file" do
    counter_catalogue
    write_counter_lock version: "2.0.0"

    farmy "start", "shop"

    assert_success
    assert_tool_pin "shop", "counter", version: "2.0.0", platform: "linux-arm64-musl", checksum: "d29ceabe164365f8efd2275f6ec57ea0a5cddeba334d52446b97e99563605446"
    assert_unchanged "tools.lock"
    assert_unchanged "farmy.yml"
  end

  test "status reports a shipped ripgrep pin newer than tools.lock and gives farmy toolbox bump as the fix" do
    select_tools "ripgrep"
    stale_ripgrep_lock

    farmy "status"

    assert_success
    assert_stdout(/ripgrep.*15\.1\.0.*(?:newer|available|outdated)|(?:newer|available|outdated).*ripgrep/im)
    assert_stdout "farmy toolbox bump"
    assert_unchanged "tools.lock"
  end
end
