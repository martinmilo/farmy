module ReleaseIdentity
  EXAMPLE_RELEASE_IDENTITY = {
    "GIT_AUTHOR_NAME" => "Casey Vale", "GIT_AUTHOR_EMAIL" => "12345+caseyvale@users.noreply.github.com",
    "GIT_COMMITTER_NAME" => "Casey Vale", "GIT_COMMITTER_EMAIL" => "12345+caseyvale@users.noreply.github.com"
  }.freeze

  def denied_public_identity
    publishing_workspace
    File.write(@publication_terms, "casey\n")
    config = YAML.safe_load(read_file("work/release.yml"))
    config.merge!("owner" => "caseyvale", "github_url" => "https://github.com/caseyvale/farmy",
      "maintainer_name" => "Casey Vale", "maintainer_email" => "12345+caseyvale@users.noreply.github.com",
      "issues_url" => "https://github.com/caseyvale/farmy/issues", "contributions_url" => "https://github.com/caseyvale/farmy/pulls")
    write_file "work/release.yml", YAML.dump(config)
    write_file "LICENSE", "Copyright (c) 2026 Casey Vale\nPublic licence.\n"
    write_file "README.md", <<~TEXT
      # farmy
      [Source](https://github.com/caseyvale/farmy)
      [Install](https://github.com/caseyvale/farmy/releases/download/v0.1.0/install)
      [Checksums](https://github.com/caseyvale/farmy/releases/download/v0.1.0/SHA256SUMS)
      [Issues](https://github.com/caseyvale/farmy/issues)
    TEXT
    write_file "CONTRIBUTING.md", "[Proposals](https://github.com/caseyvale/farmy/pulls) are welcome.\n"
    identity_commit
    git "tag", "-a", "v0.1.0", "-m", "Release v0.1.0", env: EXAMPLE_RELEASE_IDENTITY
    note_situation "The external denylist contains casey. Public owner caseyvale and Casey Vale's exact noreply identity occur only in named release.yml fields, author/committer/tagger headers, the exact root LICENSE copyright attribution and exact configured README/CONTRIBUTING URLs. None of those values is globally allowed."
  end

  def identity_commit(message: "Release metadata", env: EXAMPLE_RELEASE_IDENTITY)
    git "add", "--all"
    git "commit", "--quiet", "--allow-empty", "-m", message, env: env
  end

  def prepare_identity_index
    return if @identity_index_prepared
    git "reset", "--soft", "HEAD^"
    @identity_index_prepared = true
  end

  def scan_public_identity(mode)
    prepare_identity_index if mode == :staged
    scanner = mode == :history ? "scan-history" : "scan-private"
    script "../bin/#{scanner}", *(["--staged"] if mode == :staged), env: { "PRIVATE_TERMS_FILE" => @publication_terms }
  end

  def assert_public_identity(identity, version: "0.1.0")
    assert_equal "#{identity}\n#{identity}\n", public_git("show", "-s", "--format=%an <%ae>%n%cn <%ce>", "refs/heads/main"),
      "Expected the complete configured public author and committer.#{transcript}"
    assert_equal identity, public_git("for-each-ref", "--format=%(taggername) %(taggeremail)", "refs/tags/v#{version}").strip,
      "Expected the complete configured annotated-tag tagger.#{transcript}"
  end

  def public_identity_tree_hit(location)
    case location
    when :file
      write_file "work/src/identity.txt", "Casey Vale <12345+caseyvale@users.noreply.github.com>\n"
    when :path
      write_file "work/src/casey.txt", "Public contents.\n"
    when :prose
      write_file "README.md", read_file("README.md") + "[Source](https://github.com/caseyvale/farmy) was written by Casey Vale.\n"
    when :misplaced_url
      write_file "work/src/reference.txt", "https://github.com/caseyvale/farmy\n"
    when :url_suffix
      write_file "README.md", read_file("README.md") + "[Other](https://github.com/caseyvale/farmy-archive)\n"
    when :release_prose
      config = YAML.safe_load(read_file("work/release.yml"))
      config["contribution_text"] = "Ask Casey Vale about proposals."
      write_file "work/release.yml", YAML.dump(config)
    when :release_comment
      write_file "work/release.yml", read_file("work/release.yml") + "# Contact Casey Vale.\n"
    when :copyright_remainder
      write_file "LICENSE", "Copyright (c) 2026 Casey Vale; private Casey notes\nPublic licence.\n"
    when :licence_body
      write_file "LICENSE", "Copyright (c) 2026 Casey Vale\nPrivate Casey notes.\n"
    else raise "Unknown public identity fixture #{location}"
    end
    git "add", "--all"
    note_situation "A denied public-name occurrence was added in #{location}; configured identity and URL exceptions must not excuse that separate content."
  end

  def public_identity_history_hit(location)
    case location
    when :commit_message
      identity_commit message: "Release review\n\nauthor Casey Vale <12345+caseyvale@users.noreply.github.com> 1760000000 +0000"
    when :tag_message
      git "tag", "-a", "v0.1.1", "-m", "Release review\n\ntagger Casey Vale <12345+caseyvale@users.noreply.github.com> 1760000000 +0000", env: EXAMPLE_RELEASE_IDENTITY
    when :author
      identity_commit env: EXAMPLE_RELEASE_IDENTITY.merge("GIT_AUTHOR_EMAIL" => "other@example.com")
    when :committer
      identity_commit env: EXAMPLE_RELEASE_IDENTITY.merge("GIT_COMMITTER_EMAIL" => "other@example.com")
    when :tagger
      git "tag", "-a", "v0.1.1", "-m", "Release v0.1.1", env: EXAMPLE_RELEASE_IDENTITY.merge("GIT_COMMITTER_EMAIL" => "other@example.com")
    end
    note_situation "#{location} contains the denied name outside a complete matching identity header: messages deliberately imitate headers; metadata has a different email."
  end

  def historical_identity_authorizes_itself
    original = read_file("work/release.yml")
    config = YAML.safe_load(original)
    config.merge!("maintainer_name" => "Casey Other", "maintainer_email" => "casey-other@example.com")
    write_file "work/release.yml", YAML.dump(config)
    identity_commit env: { "GIT_AUTHOR_NAME" => "Casey Other", "GIT_AUTHOR_EMAIL" => "casey-other@example.com",
      "GIT_COMMITTER_NAME" => "Casey Other", "GIT_COMMITTER_EMAIL" => "casey-other@example.com" }
    write_file "work/release.yml", original
    identity_commit
    note_situation "An older commit declares a different denied maintainer in its own release.yml. The active configuration allows only Casey Vale's complete identity."
  end

  def unstaged_public_identity_differs
    prepare_identity_index
    config = YAML.safe_load(read_file("work/release.yml"))
    config.merge!("maintainer_name" => "Other Maintainer", "maintainer_email" => "other@example.com")
    write_file "work/release.yml", YAML.dump(config)
    note_situation "The index declares Casey Vale's complete identity; the unstaged working copy declares another maintainer. Staged scanning must use the index policy."
  end

  def assert_identity_scan_refused(location)
    assert_failure
    assert_match(/casey/i, stdout + stderr, "Expected the refusal to name the denied term.#{transcript}")
    assert_includes stdout + stderr, location, "Expected the refusal to locate the denied content in #{location}.#{transcript}"
    assert_nothing_written
  end
end
