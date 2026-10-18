class PublishingTest < AcceptanceTest
  def setup = publishing_workspace

  test "the first publish creates one parentless public release with no private development objects" do
    publish

    assert_success
    assert_public_commit_count 1
    assert_private_history_absent
    assert_only_public_release_refs
  end

  test "a later publish adds one child of the previous public tip despite several private commits" do
    published_once
    next_private_release

    publish "0.2.0"

    assert_success
    assert_public_commit_count 2
    assert_public_parent_is_previous_release
    assert_private_history_absent
  end

  test "public export retains runtime source acceptance tests spec records and executable modes" do
    publish

    assert_success
    assert_public_file "work/src/main.rs", content: "fn main() {}\n"
    assert_public_file "shape/test/run.rb", mode: "100755"
    assert_public_file "shape/spec/2026-10-15-example.md", content: "An agreed public feature record.\n"
  end

  test "public export excludes private configuration internal notes compiled products and local state" do
    publish

    assert_success
    refute_public_file ".env"
    refute_public_file "notes/internal.md"
    refute_public_file "work/target/debug/farmy"
    refute_public_file "work/.work/state.json"
  end

  test "public README and CONTRIBUTING render configured GitHub intake URLs and contribution text" do
    publish

    assert_success
    assert_exported_contribution_settings "README.md"
    assert_exported_contribution_settings "CONTRIBUTING.md"
  end

  test "public release notes retain explicitly recorded contributor credit despite squashed maintainer commits" do
    publish

    assert_success
    assert_public_file "work/releases/0.1.0.md", content: "# 0.1.0\nContributors: @example-contributor supplied the accepted proposal.\n"
  end

  test "a retained symlink points to the exported shared contract without copying private files" do
    publish

    assert_success
    assert_public_file "work/FORMATS.md", content: "../shape/FORMATS.md", mode: "120000"
    assert_public_file "shape/FORMATS.md", content: "Public executable contracts.\n"
  end

  { "missing.md" => "dangling", "../../notes/internal.md" => "excluded", "outside" => "escaping" }.each do |target, reason|
    test "a #{reason} public symlink refuses publication and leaves every public ref unchanged" do
      public_symlink target

      publish

      assert_failure
      assert_stderr(/symlink|symbolic|link/i)
      assert_public_refs_unchanged
    end
  end

  test "public author committer and tagger use configured identity instead of ambient development identity" do
    publish

    assert_success
    assert_public_release_identity
  end

  test "public messages name only the release version without private development messages or commit IDs" do
    publish

    assert_success
    assert_public_messages_are_release_only
  end

  test "publishing preserves private refs index working files and unrelated remotes" do
    publish

    assert_success
    assert_private_repository_unchanged
    assert_only_public_release_refs
  end

  test "Forgejo publication success makes no claim that GitHub mirroring or image CI completed" do
    publish

    assert_success
    assert_stdout(/public|Forgejo/i)
    assert_stdout(/GitHub.*(?:pending|separate|not verified|not checked)|(?:pending|separate|not verified|not checked).*GitHub/i)
    refute_stdout(/GitHub.*(?:completed|succeeded)|images.*published/i)
  end

  ["0.x", "v0.1.0", "0.1.0;touch marker", "0.2.0"].each do |version|
    test "publishing version #{version} refuses invalid or mismatched VERSION without public ref changes" do
      publish version

      assert_failure
      assert_stderr(/version/i)
      assert_public_refs_unchanged
      refute_file "marker"
    end
  end

  test "dirty tracked source refuses publication instead of exporting uncommitted bytes" do
    write_file "work/src/main.rs", "uncommitted source\n"

    publish

    assert_failure
    assert_stderr(/dirty|uncommitted|tracked/i)
    assert_public_refs_unchanged
    assert_private_repository_unchanged
  end

  test "repeating an identical published version succeeds as a no op without changing public refs" do
    published_once

    publish

    assert_success
    assert_stdout(/already|unchanged|no.op/i)
    assert_public_refs_unchanged
    assert_public_commit_count 1
  end

  test "different content under an existing release version is refused without moving its tag" do
    published_once
    write_file "work/src/main.rs", "fn main() { println!(\"different\"); }\n"
    commit "Different release content"

    publish

    assert_failure
    assert_stderr(/exist|conflict|different/i)
    assert_public_refs_unchanged
  end

  test "different public identity under an existing version is refused without moving its tag" do
    published_once
    change_public_identity

    publish

    assert_failure
    assert_stderr(/exist|conflict|different/i)
    assert_public_refs_unchanged
  end

  test "an older release is refused even when it matches the private VERSION" do
    published_once
    next_private_release "0.0.9"

    publish "0.0.9"

    assert_failure
    assert_stderr(/older|version|newer/i)
    assert_public_refs_unchanged
  end

  test "unexpected untagged public main history is refused without rewriting it" do
    published_once
    append_public_commit "0.1.1", tag: false
    next_private_release

    publish "0.2.0"

    assert_failure
    assert_stderr(/history|unexpected|tag|release/i)
    assert_public_refs_unchanged
  end

  test "a remote that cannot atomically update main and tag is refused without partial publication" do
    atomic_push_unavailable

    publish

    assert_failure
    assert_stderr(/atomic/i)
    assert_public_refs_unchanged
  end

  test "a concurrent public tip change preserves that tip and cannot leave a partial release tag" do
    published_once
    next_private_release

    publish "0.2.0", env: publication_remote_race

    assert_failure
    assert_stderr(/changed|race|stale|reject|push|fetch/i)
    assert_race_left_no_release_tag
  end

  test "a rejected publication is retryable with exactly one public release commit" do
    reject_public_push
    publish
    assert_failure
    assert_public_refs_unchanged
    allow_public_push

    publish

    assert_success
    assert_public_commit_count 1
    assert_private_history_absent
  end
end
