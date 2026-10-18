class PublishingPrivacyTest < AcceptanceTest
  def setup = publishing_workspace

  { "work/src/main.rs" => "private-development-note\n", "work/src/private-development-note.txt" => "public text\n",
    "work/src/asset.bin" => "\0private-development-note\0" }.each do |path, contents|
    test "a privacy hit in exported #{path} refuses publication before any remote ref changes" do
      write_file path, contents
      commit "Export input"

      publish

      assert_failure
      assert_stderr(/privacy|private|denylist|scan/i)
      assert_public_refs_unchanged
    end
  end

  test "a denied value in a public symlink target refuses publication" do
    write_file "work/src/private-development-note.txt", "public target\n"
    public_symlink "private-development-note.txt"

    publish

    assert_failure
    assert_stderr(/privacy|private|denylist|scan/i)
    assert_public_refs_unchanged
  end

  [:unset, :missing, :empty, :unreadable].each do |kind|
    test "a #{kind} publication denylist refuses every push rather than skipping the privacy check, naming PRIVATE_TERMS_FILE" do
      publication_denylist kind

      publish

      assert_failure
      assert_stderr "PRIVATE_TERMS_FILE"
      assert_public_refs_unchanged
    end
  end

  test "scan-private refuses to run when PRIVATE_TERMS_FILE is unset, naming the variable" do
    scan_private_with ""

    assert_failure
    assert_stderr "PRIVATE_TERMS_FILE"
  end

  test "scan-private refuses to run when PRIVATE_TERMS_FILE names a file that does not exist, naming the path" do
    scan_private_with "/nonexistent/denylist"

    assert_failure
    assert_stderr "/nonexistent/denylist"
  end

  ["scan-private", "scan-history"].each do |scanner|
    test "failure to execute #{scanner} refuses publication and leaves public refs unchanged" do
      publication_scanner_fails scanner

      publish

      assert_failure
      assert_stderr(/scanner|scan|failed/i)
      assert_public_refs_unchanged
    end
  end

  test "a privacy hit in deleted historical public content still blocks the next release" do
    published_once
    append_public_commit "0.1.1", changes: { "work/src/old.txt" => "private-development-note\n" }
    append_public_commit "0.1.2", changes: { "work/src/old.txt" => nil }
    next_private_release

    publish "0.2.0"

    assert_failure
    assert_stderr(/privacy|private|denylist|scan/i)
    assert_public_refs_unchanged
  end

  test "a privacy hit in a previous public commit author blocks the next release" do
    published_once
    append_public_commit "0.1.1", author: "private-author@example.com"
    next_private_release

    publish "0.2.0"

    assert_failure
    assert_stderr(/privacy|private|denylist|scan/i)
    assert_public_refs_unchanged
  end

  test "a privacy hit in annotated release tag metadata blocks the next release" do
    published_once
    append_public_commit "0.1.1", tag_message: "private-tag-note"
    next_private_release

    publish "0.2.0"

    assert_failure
    assert_stderr(/privacy|private|denylist|scan/i)
    assert_public_refs_unchanged
  end
end
