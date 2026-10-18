require "yaml"
require "shellwords"
require "pathname"

module Publishing
  PUBLIC_IDENTITY = { "GIT_AUTHOR_NAME" => "farmy maintainers", "GIT_AUTHOR_EMAIL" => "maintainers@example.com",
    "GIT_COMMITTER_NAME" => "farmy maintainers", "GIT_COMMITTER_EMAIL" => "maintainers@example.com" }.freeze
  PRIVATE_MARKERS = %w[internal-only.example.com private-development-note private-author@example.com private-tag-note].freeze

  def public_artifact(relative)
    path = Target.path("../#{relative}")
    assert File.file?(path), "Expected the shipped public artifact #{relative}."
    File.read(path)
  end

  def publishing_workspace
    @public_remote = File.join(scratch, "public.git")
    @other_remote = File.join(scratch, "other.git")
    [@public_remote, @other_remote].each { |path| outside_git "init", "--quiet", "--bare", "--initial-branch=main", path }
    @publication_terms = File.join(scratch, "publication-denylist")
    File.write(@publication_terms, PRIVATE_MARKERS.join("\n") + "\n")
    write_file "work/release.yml", YAML.dump({ "owner" => "acme", "github_url" => "https://github.com/acme/farmy",
      "public_remote" => "public", "maintainer_name" => "farmy maintainers", "maintainer_email" => "maintainers@example.com",
      "issues_url" => "https://github.com/acme/farmy/issues", "contributions_url" => "https://github.com/acme/farmy/pulls",
      "contribution_text" => "GitHub PRs are proposals; maintainers apply accepted changes in the source repository, release them next time, and credit contributors in release notes." })
    write_file "work/public-files.txt", "# Reviewed public inputs\nREADME.md\nCONTRIBUTING.md\nLICENSE\nbin/\n.github/\nwork/VERSION\nwork/release.yml\nwork/public-files.txt\nwork/Dockerfile\nwork/src/\nwork/releases/\nwork/FORMATS.md\nshape/FORMATS.md\nshape/test/\nshape/spec/\n"
    write_file "work/VERSION", "0.1.0\n"
    write_file "README.md", "# farmy\nPublic source distribution.\n"
    write_file "CONTRIBUTING.md", "GitHub issues and proposal PRs are welcome.\n"
    write_file "LICENSE", "Copyright (c) farmy maintainers\nPublic licence.\n"
    write_file "work/Dockerfile", "FROM scratch\nCOPY src/ /src/\n"
    write_file "work/src/main.rs", "fn main() {}\n"
    write_file "work/releases/0.1.0.md", "# 0.1.0\nContributors: @example-contributor supplied the accepted proposal.\n"
    write_file "shape/FORMATS.md", "Public executable contracts.\n"
    write_file "shape/spec/2026-10-15-example.md", "An agreed public feature record.\n"
    write_executable "shape/test/run.rb", "#!/usr/bin/env ruby\nputs 'public acceptance tests'\n"
    File.symlink("../shape/FORMATS.md", File.join(dir, "work/FORMATS.md"))
    write_file ".github/workflows/release.yml", "name: release\non: {push: {tags: ['v*']}}\njobs: {}\n"
    %w[scan-private scan-history].each do |scanner|
      source = Target.path("../bin/#{scanner}")
      assert File.executable?(source), "Expected shipped bin/#{scanner} for publication validation."
      FileUtils.mkdir_p(File.join(dir, "bin"))
      FileUtils.cp(source, File.join(dir, "bin", scanner), preserve: true)
    end
    write_file ".env", "PRIVATE_HOST=internal-only.example.com\n"
    write_file "notes/internal.md", "private-development-note\n"
    write_file "work/target/debug/farmy", "compiled development product\n"
    write_file "work/.work/state.json", "{}\n"
    start_repository
    git "remote", "add", "public", @public_remote
    git "remote", "add", "unrelated", @other_remote
    git "remote", "add", "origin", "ssh://dev@internal-only.example.com/private/farmy.git"
    commit_private_change
    git "branch", "private-topic"
    git "tag", "private-development-tag"
    @private_commits = git("rev-list", "--all").lines.map(&:strip)
    @publish_git = ENV.fetch("PATH").split(":").map { |part| File.join(part, "git") }.find { |path| File.executable?(path) && !File.directory?(path) }
    @push_log = File.join(scratch, "publish-pushes.jsonl")
    @publish_bin = File.join(scratch, "publishing-os").tap { |path| FileUtils.mkdir_p(path) }
    File.write(File.join(@publish_bin, "git"), <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      require "open3"
      if ARGV.include?("push")
        File.open(ENV.fetch("PUBLISH_PUSH_LOG"), "a") { |log| log.puts(JSON.generate(ARGV)) }
        if ENV["PUBLISH_RACE_SHA"] && !File.exist?(ENV.fetch("PUBLISH_RACE_ONCE"))
          File.write(ENV.fetch("PUBLISH_RACE_ONCE"), "raced")
          out, status = Open3.capture2e(#{@publish_git.dump}, "--git-dir", ENV.fetch("PUBLISH_RACE_REMOTE"), "update-ref", "refs/heads/main", ENV.fetch("PUBLISH_RACE_SHA"))
          abort out unless status.success?
        end
      end
      exec(#{@publish_git.dump}, *ARGV)
    RUBY
    File.chmod(0755, File.join(@publish_bin, "git"))
    note_situation "The temporary private repository has work/ and shape/, private history/refs and excluded files; public is an isolated local bare remote. Publication may push only public main and its release tag."
  end

  def commit_private_change
    commit "private-development-note", on: "2026-01-16T12:00:00Z"
    git "commit", "--quiet", "--allow-empty", "--message", "Private source change", env: {
      "GIT_AUTHOR_NAME" => "Private Developer", "GIT_AUTHOR_EMAIL" => "private-author@example.com",
      "GIT_COMMITTER_NAME" => "Private Developer", "GIT_COMMITTER_EMAIL" => "private-author@example.com" }
  end

  def outside_git(*arguments, env: {})
    out, status = Open3.capture2e(Workspace::GIT_ENV.merge(env), "git", *arguments)
    raise "Git fixture #{arguments.join(' ')} failed: #{out}" unless status.success?
    out
  end

  def public_git(*arguments) = outside_git("--git-dir", @public_remote, *arguments)

  def publish(version = "0.1.0", env: {})
    @before_public_refs = public_git("for-each-ref", "--format=%(refname) %(objectname)")
    @before_private_refs = git("for-each-ref", "--format=%(refname) %(objectname)")
    @before_private_status = git("status", "--porcelain=v1", "--untracked-files=all")
    @before_index = Digest::SHA256.file(File.join(dir, ".git/index")).hexdigest
    @before_other_refs = outside_git("--git-dir", @other_remote, "for-each-ref", "--format=%(refname) %(objectname)")
    plumbing = { "PATH" => [@publish_bin, ENV.fetch("PATH")].join(":"), "PUBLISH_PUSH_LOG" => @push_log }.merge(env)
    saved = plumbing.keys.to_h { |key| [key, ENV[key]] }
    plumbing.each { |key, value| ENV[key] = value }
    script "../bin/publish", version, env: { "PRIVATE_TERMS_FILE" => @publication_terms }
  ensure
    saved&.each { |key, value| ENV[key] = value }
  end

  def published_once
    publish
    assert_success
    @first_public_commit = public_git("rev-parse", "refs/heads/main").strip
  end

  def next_private_release(version = "0.2.0")
    write_file "work/VERSION", "#{version}\n"
    write_file "work/releases/#{version}.md", "# #{version}\nPublic release notes.\n"
    write_file "work/src/main.rs", "fn main() { println!(\"public update\"); }\n"
    commit "Private intermediate work"
    commit_private_change
    @private_commits = git("rev-list", "--all").lines.map(&:strip)
  end

  def assert_public_commit_count(count)
    refs = public_git("for-each-ref", "--format=%(refname)")
    assert_includes refs, "refs/heads/main", "Expected a public main branch.#{transcript}"
    assert_equal count, public_git("rev-list", "--count", "refs/heads/main").to_i, "Expected exactly #{count} public release commits.#{transcript}"
  end

  def assert_public_parent_is_previous_release
    assert_equal @first_public_commit, public_git("show", "-s", "--format=%P", "refs/heads/main").strip,
      "Expected the previous public tip as the sole parent, with no private development parent.#{transcript}"
  end

  def assert_private_history_absent
    public_commits = public_git("rev-list", "--all").lines.map(&:strip)
    assert_empty public_commits & @private_commits, "Expected no private development commit reachable from any public ref.#{transcript}"
    @private_commits.each do |sha|
      _, status = Open3.capture2e(Workspace::GIT_ENV, "git", "--git-dir", @public_remote, "cat-file", "-e", "#{sha}^{commit}")
      refute status.success?, "Expected private development object #{sha} never to reach the public repository.#{transcript}"
    end
  end

  def assert_public_file(path, content: nil, mode: nil)
    files = public_git("ls-tree", "-r", "--name-only", "refs/heads/main").lines.map(&:strip)
    assert_includes files, path, "Expected the public export to include #{path}.#{transcript}"
    assert_equal content, public_git("show", "refs/heads/main:#{path}"), "Expected committed public bytes at #{path}.#{transcript}" if content
    assert public_git("ls-tree", "refs/heads/main", "--", path).start_with?(mode), "Expected public #{path} mode #{mode}.#{transcript}" if mode
  end

  def assert_exported_contribution_settings(path)
    contents = public_git("show", "refs/heads/main:#{path}")
    config = YAML.safe_load(read_file("work/release.yml"))
    %w[issues_url contributions_url contribution_text].each do |key|
      assert contents.include?(config.fetch(key)), "Expected exported #{path} to render configured #{key}.#{transcript}"
    end
  end

  def refute_public_file(path)
    refute_includes public_git("ls-tree", "-r", "--name-only", "refs/heads/main").lines.map(&:strip), path,
      "Expected #{path} excluded from the public tree.#{transcript}"
  end

  def assert_public_release_identity
    assert_equal "farmy maintainers <maintainers@example.com>\nfarmy maintainers <maintainers@example.com>\n",
      public_git("show", "-s", "--format=%an <%ae>%n%cn <%ce>", "refs/heads/main"), "Expected configured author and committer despite ambient identity.#{transcript}"
    assert_equal "farmy maintainers <maintainers@example.com>", public_git("for-each-ref", "--format=%(taggername) %(taggeremail)", "refs/tags/v0.1.0").strip,
      "Expected configured annotated-tag tagger.#{transcript}"
  end

  def assert_public_messages_are_release_only
    metadata = public_git("log", "--all", "--format=fuller") + public_git("for-each-ref", "--format=%(contents)", "refs/tags")
    assert_includes metadata, "0.1.0", "Expected neutral release messages naming the version.#{transcript}"
    (PRIVATE_MARKERS + @private_commits).each { |value| refute_includes metadata, value, "Expected no private history/identity in public metadata.#{transcript}" }
  end

  def assert_public_refs_unchanged
    assert_equal @before_public_refs, public_git("for-each-ref", "--format=%(refname) %(objectname)"), "Expected every public ref unchanged after refusal/no-op.#{transcript}"
  end

  def assert_private_repository_unchanged
    assert_equal @before_private_refs, git("for-each-ref", "--format=%(refname) %(objectname)"), "Expected private refs untouched.#{transcript}"
    assert_equal @before_private_status, git("status", "--porcelain=v1", "--untracked-files=all"), "Expected private working tree unchanged.#{transcript}"
    assert_equal @before_index, Digest::SHA256.file(File.join(dir, ".git/index")).hexdigest, "Expected private index unchanged.#{transcript}"
    assert_nothing_written
  end

  def assert_only_public_release_refs(version = "0.1.0")
    assert_equal ["refs/heads/main", "refs/tags/v#{version}"], public_git("for-each-ref", "--format=%(refname)").lines.map(&:strip).sort,
      "Expected only public main and release tag, without private branches/tags/notes.#{transcript}"
    assert_equal @before_other_refs, outside_git("--git-dir", @other_remote, "for-each-ref", "--format=%(refname) %(objectname)"), "Expected unrelated remote untouched.#{transcript}"
    assert_equal public_git("rev-parse", "refs/heads/main").strip, public_git("rev-parse", "refs/tags/v#{version}^{commit}").strip
    calls = File.file?(@push_log) ? File.readlines(@push_log).map { |line| JSON.parse(line) } : []
    assert_equal 1, calls.length, "Expected one push for main and tag together.#{transcript}"
    assert_includes calls.first, "--atomic", "Expected the public refs pushed atomically.#{transcript}"
  end

  def publication_denylist(kind)
    case kind
    when :unset then @publication_terms = ""
    when :missing then FileUtils.rm_f(@publication_terms)
    when :empty then File.write(@publication_terms, "# no rules\n\n")
    when :unreadable then File.chmod(0000, @publication_terms)
    end
    note_situation "The required publication denylist is #{kind}."
  end

  # bin/scan-private on the test's repository, with PRIVATE_TERMS_FILE set to terms ("" counts as unset).
  def scan_private_with(terms)
    script "../bin/scan-private", env: { "PRIVATE_TERMS_FILE" => terms }
  end

  def publication_scanner_fails(name)
    write_executable "bin/#{name}", "#!/bin/sh\necho 'scanner execution failed' >&2\nexit 73\n"
    commit "Public scanner fixture"
  end

  def public_symlink(target)
    if target == "outside"
      outside = File.join(scratch, "outside-public.txt")
      File.write(outside, "An existing file outside the exported repository.\n")
      target = Pathname.new(outside).relative_path_from(Pathname.new(File.join(dir, "work/src"))).to_s
    end
    File.symlink(target, File.join(dir, "work/src/public-link"))
    commit "Public link input"
  end

  def change_public_identity
    config = YAML.safe_load(read_file("work/release.yml"))
    config["maintainer_name"] = "Other Public Maintainers"
    write_file "work/release.yml", YAML.dump(config)
    commit "Public metadata changed"
  end

  def append_public_commit(version, changes: {}, author: nil, message: nil, tag_message: nil, tag: true)
    checkout = File.join(scratch, "public-edit-#{version}")
    outside_git "clone", "--quiet", @public_remote, checkout
    changes.each do |path, contents|
      local = File.join(checkout, path)
      contents.nil? ? FileUtils.rm_f(local) : (FileUtils.mkdir_p(File.dirname(local)); File.write(local, contents))
    end
    File.write(File.join(checkout, "work/VERSION"), "#{version}\n")
    FileUtils.mkdir_p(File.join(checkout, "work/releases"))
    File.write(File.join(checkout, "work/releases/#{version}.md"), "# #{version}\nPublic release notes.\n")
    outside_git "-C", checkout, "add", "--all"
    identity = PUBLIC_IDENTITY.merge(author ? { "GIT_AUTHOR_EMAIL" => author } : {})
    outside_git "-C", checkout, "commit", "--quiet", "--allow-empty", "-m", message || "Release v#{version}", env: identity
    outside_git "-C", checkout, "tag", "-a", "v#{version}", "-m", tag_message || "Release v#{version}", env: PUBLIC_IDENTITY if tag
    outside_git "-C", checkout, "push", "--quiet", "origin", "main", *(tag ? ["refs/tags/v#{version}"] : [])
  end

  def reject_public_push
    path = File.join(@public_remote, "hooks/pre-receive")
    File.write(path, "#!/bin/sh\necho 'publication temporarily unavailable' >&2\nexit 1\n")
    File.chmod(0755, path)
  end

  def allow_public_push = FileUtils.rm_f(File.join(@public_remote, "hooks/pre-receive"))

  def atomic_push_unavailable
    public_git "config", "receive.advertiseAtomic", "false"
  end

  def publication_remote_race
    tree = public_git("rev-parse", "refs/heads/main^{tree}").strip
    parent = public_git("rev-parse", "refs/heads/main").strip
    @racing_public_commit = public_git("commit-tree", tree, "-p", parent, "-m", "Concurrent public release").strip
    { "PUBLISH_RACE_SHA" => @racing_public_commit, "PUBLISH_RACE_REMOTE" => @public_remote,
      "PUBLISH_RACE_ONCE" => File.join(scratch, "race-once") }
  end

  def assert_race_left_no_release_tag
    assert_equal @racing_public_commit, public_git("rev-parse", "refs/heads/main").strip, "Expected the concurrent remote tip preserved.#{transcript}"
    refute_includes public_git("for-each-ref", "--format=%(refname)"), "refs/tags/v0.2.0", "Expected no partial release tag after a remote-tip race.#{transcript}"
  end
end
