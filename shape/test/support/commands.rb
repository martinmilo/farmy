# Running the program, or any other executable in the work folder. The kit is for
# command-line programs: a command, in a folder, with files.
#
#   cli "redeem", "GIFT-2041"        the program (PROGRAM in test_helper.rb)
#   script "bin/backup", "data"      any executable in the work folder
#
# Each one runs in the test's workspace and remembers its result for the
# assertions below. Options: stdin: "text", env: { "NAME" => "value" }.
require "open3"

module Commands
  COMMAND_TIMEOUT = 60 # suite watchdog, not a product response-time contract

  Finished = Struct.new(:line, :stdout, :stderr, :exit, :situation) do
    def to_s
      ["  $ #{line}", "  exit #{exit}", stream("stdout", stdout), stream("stderr", stderr), *before].join("\n")
    end

    # What a helper put in place before the command ran and the transcript alone would not show.
    def before
      return [] if situation.empty?
      ["", "  Before the command:", *situation.map { |note| note.gsub(/^/, "    ") }]
    end

    def stream(name, text)
      return "  #{name}: (empty)" if text.empty?
      shown = text.lines.first(40).join
      shown += "    … #{text.lines.size - 40} more lines\n" if text.lines.size > 40
      "  #{name}:\n#{shown.gsub(/^/, "    ").chomp}"
    end
  end

  def cli(*args, **options)
    execute Target.path(PROGRAM), args, shown_as: File.basename(PROGRAM), **options
  end

  def script(path, *args, **options)
    execute Target.path(path), args, shown_as: path, **options
  end

  def stdout = finished.stdout
  def stderr = finished.stderr

  def assert_success = assert_exit(0)

  def assert_failure
    assert finished.exit != 0, "Expected the command to fail, but it exited 0.\n\n#{finished}"
  end

  def assert_exit(code)
    assert finished.exit == code, "Expected exit #{code}, got #{finished.exit}.\n\n#{finished}"
  end

  def assert_stdout(text) = assert_stream("stdout", stdout, text)
  def assert_stderr(text) = assert_stream("stderr", stderr, text)
  def refute_stdout(text) = refute_stream("stdout", stdout, text)
  def refute_stderr(text) = refute_stream("stderr", stderr, text)

  # The whole of stdout, character for character. For output whose layout is the feature.
  def assert_stdout_is(text)
    assert_same_text text, stdout, "The output of `#{finished.line}`", after: "\n\n#{finished}"
  end

  # Said by a helper about what it set up; shown under the transcript when a test fails.
  def note_situation(text)
    situation << text
  end

  # Every line of stdout fits in the given number of columns. For plain-text screens.
  def assert_lines_within(columns)
    long = stdout.lines.map(&:chomp).select { |line| line.length > columns }
    shown = long.map { |line| "  #{line.length} columns: #{line}" }.join("\n")
    assert long.empty?, "Expected every line of stdout to fit in #{columns} columns. These do not:\n\n#{shown}\n\n#{finished}"
  end

  # stdout has exactly this many lines.
  def assert_stdout_lines(count)
    assert_equal count, stdout.lines.size, "Expected stdout to be #{count} line(s), got #{stdout.lines.size}.\n\n#{finished}"
  end

  private

  def situation = @situation ||= []

  def finished
    @finished or raise Minitest::Assertion, "No command has been run in this test yet."
  end

  def assert_stream(name, actual, text)
    assert text === actual || actual.include?(text.to_s), "Expected #{name} to include #{text.inspect}.\n\n#{finished}"
  end

  def refute_stream(name, actual, text)
    refute text === actual || actual.include?(text.to_s), "Expected #{name} not to include #{text.inspect}.\n\n#{finished}"
  end

  def execute(executable, args, shown_as:, stdin: "", env: {})
    args = args.map(&:to_s)
    line = [shown_as, *args.map { |arg| arg.to_s.match?(/\A[\w\-.\/:=@,+]+\z/) ? arg.to_s : arg.to_s.inspect }].join(" ")
    line = "#{env.map { |name, value| "#{name}=#{value.match?(/\A[\w\-.\/:=@,+]+\z/) ? value : value.inspect}" }.join(" ")} #{line}" unless env.empty?

    unless File.executable?(executable)
      raise Minitest::Assertion, "The tests run #{executable.delete_prefix("#{Target.root}/")} in the work folder, and nothing executable is there.\n\n  $ #{line}"
    end

    remember_workspace
    before = [*situation, *repository_state]
    # Git inside the program behaves the same on every machine: fixed identity, no user or system config.
    # Its own process group, so that a timeout stops everything the program started.
    Open3.popen3(Workspace::GIT_ENV.merge(env.transform_values(&:to_s)), executable, *args, chdir: dir, pgroup: true) do |input, output, error, waiter|
      begin
        input.write(stdin)
      rescue Errno::EPIPE
        # The program stopped reading its input; its exit code and output say why.
      end
      input.close
      out = Thread.new { output.read.scrub }
      err = Thread.new { error.read.scrub }
      [out, err].each { |reader| reader.report_on_exception = false }
      unless waiter.join(COMMAND_TIMEOUT)
        Process.kill("KILL", -waiter.pid) # the whole process group, see pgroup above
        waiter.join
        raise Minitest::Assertion, "The command was still running after #{COMMAND_TIMEOUT} s and was stopped.\n\n  $ #{line}"
      end
      status = waiter.value
      @finished = Finished.new(line, out.value, err.value, status.exitstatus || "none (killed by signal #{status.termsig})", before)
    end
  end
end
