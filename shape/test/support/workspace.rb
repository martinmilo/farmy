# Every test gets its own empty folder; commands run inside it.
#
#   workspace "shop"                 start from a copy of test/fixtures/workspaces/shop
#   workspace "shop", git: true      ...committed as a Git repository
#   commit "Redeem GIFT-2041"        stage everything and commit it
#   commit "...", on: "2026-10-05"   ...with that commit date
#   branch "x" · switch_to "main" · merge "x", on: "2026-10-07"    a side branch, merged back
#   folder_named "shop"              the test's folder is called shop; comes first in a test
#   write_file "notes.txt", "..."    add or replace a file
#   write_executable "bin/x", "..."  ...that can be run
#   edit_file "notes.txt"            change a file that is already there, without saying how
#   start_repository                 make the folder, as it is now, a Git repository with one commit
#
#   assert_file "out/report.txt"                       it exists
#   assert_file "out/report.txt", includes: "3 rows"
#   assert_file "out/report.txt", is: expected("report.txt")
#   refute_file "out/report.txt"
#   assert_nothing_written           the last command left every file as it was
#   assert_written_only "out/a.txt"  ...created or changed this file and no other
#   assert_unchanged "data.json"     the last command left this file as it was
require "open3"
require "tmpdir"
require "fileutils"
require "digest"

module Workspace
  GIT_ENV = {
    "GIT_AUTHOR_NAME" => "Acceptance Tests", "GIT_AUTHOR_EMAIL" => "tests@example.com",
    "GIT_COMMITTER_NAME" => "Acceptance Tests", "GIT_COMMITTER_EMAIL" => "tests@example.com",
    "GIT_AUTHOR_DATE" => "2026-01-15T09:00:00+01:00", "GIT_COMMITTER_DATE" => "2026-01-15T09:00:00+01:00",
    "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1"
  }.freeze

  def dir
    @dir ||= Dir.mktmpdir("workspace-")
  end

  # For behaviour that depends on what the folder is called.
  def folder_named(name)
    raise ArgumentError, "folder_named comes before anything else uses the test's folder" if @dir
    @parent = Dir.mktmpdir("workspace-")
    note_situation "The folder the command runs in is called #{name}."
    @dir = File.join(@parent, name).tap { |path| Dir.mkdir(path) }
  end

  def workspace(name, git: false)
    source = File.join(TEST_ROOT, "fixtures", "workspaces", name)
    raise ArgumentError, "No fixture workspace at #{source}" unless File.directory?(source)
    FileUtils.cp_r(File.join(source, "."), dir)
    start_repository if git
  end

  # Turns the folder as it is now into a Git repository with one commit, dated as GIT_ENV says.
  def start_repository
    git "init", "--quiet", "--initial-branch=main"
    commit "Initial state"
  end

  def write_file(path, content)
    FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
    File.write(File.join(dir, path), content)
  end

  def write_executable(path, content)
    write_file path, content
    File.chmod(0o755, File.join(dir, path))
  end

  # Changes what is in a file without saying how: one more empty line at its end, which every
  # text format tolerates. For a change the program must notice in the content, use write_file.
  def edit_file(path)
    write_file path, "#{read_file(path)}\n"
  end

  def delete_file(path) = FileUtils.rm(File.join(dir, path))
  def read_file(path)   = File.read(File.join(dir, path))

  def git(*args, env: {})
    output, status = Open3.capture2e(GIT_ENV.merge(env), "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed in the test's workspace:\n#{output}" unless status.success?
    output
  end

  # Without on: the commit has the fixed date in GIT_ENV. on: "2026-10-05" is noon UTC on that
  # day; a full timestamp, on: "2026-10-03T00:00:00+00:00", is taken as written.
  def commit(message = "Change", on: nil)
    git "add", "--all"
    git "commit", "--quiet", "--allow-empty", "--message", message, env: commit_date(on)
  end

  # A side branch and back: branch "longer-reminders" starts one and moves to it,
  # switch_to "main" moves back, merge "longer-reminders" brings it in as a merge commit.
  def branch(name)    = git("switch", "--quiet", "--create", name)
  def switch_to(name) = git("switch", "--quiet", name)

  def merge(name, on: nil)
    git "merge", "--quiet", "--no-ff", "--message", "Merge #{name}", name, env: commit_date(on)
  end

  def assert_file(path, is: nil, includes: nil)
    assert File.file?(File.join(dir, path)), "Expected a file at #{path}.\n\n#{listing}#{transcript}"
    assert_same_text is, read_file(path), path, after: transcript if is
    assert read_file(path).include?(includes), "Expected #{path} to include #{includes.inspect}.\n\n  #{path}:\n#{read_file(path).gsub(/^/, "    ")}#{transcript}" if includes
  end

  def refute_file(path)
    refute File.exist?(File.join(dir, path)), "Expected no file at #{path}.\n\n#{listing}#{transcript}"
  end

  def assert_nothing_written
    assert file_changes.empty?, "Expected the command to leave every file as it was.\n\n#{file_changes.join("\n").gsub(/^/, "  ")}#{transcript}"
  end

  def assert_written_only(*paths)
    written = file_changes.reject { |change| change.start_with?("deleted") }.map { |change| change.split(/\s+/, 2).last }
    shown = file_changes.empty? ? "  It wrote nothing." : file_changes.join("\n").gsub(/^/, "  ")
    assert written.sort == paths.sort && written.size == file_changes.size,
           "Expected the command to write #{paths.join(", ")} and no other file.\n\n#{shown}#{transcript}"
  end

  def assert_unchanged(path)
    before = @remembered or raise Minitest::Assertion, "No command has been run in this test yet, so nothing can be unchanged."
    assert before.key?(path), "Expected the command to leave #{path} as it was, but there was no such file before the command.\n\n#{listing}#{transcript}"
    assert before[path] == snapshot[path], "Expected the command to leave #{path} as it was.#{transcript}"
  end

  def after_teardown
    super
    FileUtils.remove_entry(@parent || @dir) if @dir
  end

  private

  def commit_date(on)
    return {} unless on
    moment = on.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? "#{on}T12:00:00+00:00" : on
    unless moment.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})\z/)
      raise ArgumentError, "commit on: takes a date or a timestamp with a zone, not #{on.inspect}"
    end
    { "GIT_AUTHOR_DATE" => moment, "GIT_COMMITTER_DATE" => moment }
  end

  # What Git holds in the test folder, for the transcript of a failure: the program reads it,
  # and nothing the command line shows would tell one history from another.
  def repository_state
    return [] unless File.directory?(File.join(dir, ".git"))
    log, status = Open3.capture2e(GIT_ENV, "git", "log", "--format=%x00%cI  %s", "--name-only", chdir: dir)
    return ["The folder is a Git repository with no commits yet."] unless status.success?
    commits = log.split("\0").reject(&:empty?).map do |entry|
      heading, *files = entry.lines.map(&:chomp).reject(&:empty?)
      files = ["(#{files.size} files)"] if files.size > 6
      ["  #{heading}", *files.map { |file| "      #{file}" }].join("\n")
    end
    pending = git("status", "--short", "--untracked-files=all").chomp
    pending = pending.empty? ? "Nothing is uncommitted." : "Not committed, as git status --short shows it:\n#{pending.gsub(/^/, "  ")}"
    ["The folder is a Git repository. Its commits, newest first, with the commit date and the files each touched:\n#{commits.join("\n")}\n#{branches}#{pending}"]
  end

  # Dates do not show which commit follows which once a branch was merged; the graph does.
  def branches
    return "" if git("rev-list", "--merges", "HEAD").empty?
    "A branch was merged. The same commits as git log --graph draws them:\n#{git("log", "--graph", "--format=%s").chomp.gsub(/^/, "  ")}\n"
  end

  def remember_workspace
    @remembered = snapshot
  end

  # What the last command did to the files: "created  path", "changed  path", "deleted  path".
  def file_changes
    before, after = @remembered || {}, snapshot
    ((after.keys - before.keys).map { |path| "created  #{path}" } +
     (before.keys - after.keys).map { |path| "deleted  #{path}" } +
     (before.keys & after.keys).reject { |path| before[path] == after[path] }.map { |path| "changed  #{path}" }).sort
  end

  def transcript = @finished ? "\n\n#{@finished}" : ""

  def snapshot
    Dir.glob("**/*", File::FNM_DOTMATCH, base: dir)
       .reject { |path| path.start_with?(".git/") || path == ".git" || !File.file?(File.join(dir, path)) }
       .each_with_object({}) do |path, files|
         begin
           files[path] = Digest::SHA256.file(File.join(dir, path)).hexdigest
         rescue Errno::ENOENT
           # A detached controller may atomically rename a file after glob saw it.
           # Only the vanished path is absent; other read errors still fail the test.
         end
       end
  end

  def listing
    files = snapshot.keys.sort
    files.empty? ? "  The workspace is empty." : "  Files in the workspace:\n#{files.join("\n").gsub(/^/, "    ")}"
  end
end
