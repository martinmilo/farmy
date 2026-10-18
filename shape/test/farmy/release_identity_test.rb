class ReleaseIdentityTest < AcceptanceTest
  def setup = denied_public_identity # Casey Vale is configured publicly; "casey" remains denied.

  [:tree, :staged, :history].each do |mode|
    test "the #{mode} scan accepts only the configured release identity LICENSE attribution and exact public document URLs" do
      scan_public_identity mode

      assert_success
      assert_nothing_written
    end
  end

  test "publication accepts a denied configured identity and uses it for public author committer and tagger" do
    publish

    assert_success
    assert_public_identity "Casey Vale <12345+caseyvale@users.noreply.github.com>"
    assert_private_history_absent
  end

  test "a later release accepts the same configured identity and earlier public installer links in history" do
    published_once
    next_private_release

    publish "0.2.0"

    assert_success
    assert_public_commit_count 2
    assert_public_identity "Casey Vale <12345+caseyvale@users.noreply.github.com>", version: "0.2.0"
  end

  {
    file: "work/src/identity.txt", path: "work/src/casey.txt", prose: "README.md",
    misplaced_url: "work/src/reference.txt", url_suffix: "README.md",
    release_prose: "work/release.yml", release_comment: "work/release.yml",
    copyright_remainder: "LICENSE", licence_body: "LICENSE"
  }.each do |location, path|
    test "the configured public name in #{location} remains denied and reports #{path}" do
      public_identity_tree_hit location

      scan_public_identity :tree

      assert_identity_scan_refused path
    end
  end

  test "a configured identity copied into an ordinary file blocks publication before any public ref changes" do
    public_identity_tree_hit :file
    commit "Public export input"

    publish

    assert_failure
    assert_match(/work\/src\/identity\.txt/, stdout + stderr)
    assert_public_refs_unchanged
  end

  { commit_message: "commit", tag_message: "tag", author: "commit", committer: "commit", tagger: "tag" }.each do |location, scope|
    test "history refuses #{location} containing the denied name unless it is an exact configured identity header" do
      public_identity_history_hit location

      scan_public_identity :history

      assert_identity_scan_refused scope
    end
  end

  test "historical release configuration cannot authorize a different denied public identity" do
    historical_identity_authorizes_itself

    scan_public_identity :history

    assert_identity_scan_refused "commit"
  end

  test "the staged privacy scan uses the staged release identity when the working copy declares a different identity" do
    unstaged_public_identity_differs

    scan_public_identity :staged

    assert_success
    assert_nothing_written
  end
end
