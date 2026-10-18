# Entry point for the suite. bin/verify in the work folder calls it; the shaper runs it as
# ruby test/run.rb. Both build the program first when ../work/bin/build exists.
#
#   ruby test/run.rb            the work in hand: every test file this branch adds or changes
#                               since it left the trunk, committed or not
#   ruby test/run.rb --all      every test file
#   ruby test/run.rb -n /redeem/ -v      any Minitest option passes through
#
# The shaper commits each piece of work on its own branch and the worker continues on it,
# so the branch's own test files are the list, and nobody maintains one by hand.
#
# Tests run in parallel, one process per test, as many at a time as the machine has processors
# (JOBS=4 to choose, JOBS=1 to run everything in this one process, as Minitest would). Every test
# has a folder of its own, so they never interfere. The report reads as Minitest's: progress, the
# failures, one total line.
require "open3"
require "etc"
require "tempfile"
require_relative "support/target"

TRUNK = "main" # the branch that pieces of work start from
ALWAYS = ["test/farmy/nothing_private_test.rb"] # run with the work in hand every time: the repository is public

abort "The test kit needs Ruby 3.0 or later; this is #{RUBY_VERSION}." if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.0")
git_version = `git --version 2>/dev/null`[/\d+(\.\d+)+/] or abort "The test kit needs Git 2.28 or later, and git is not on the PATH."
abort "The test kit needs Git 2.28 or later; this is #{git_version}." if Gem::Version.new(git_version.split(".").first(3).join(".")) < Gem::Version.new("2.28")

shape = File.expand_path("..", __dir__)
Dir.chdir(shape)

def trunk
  [TRUNK, "origin/#{TRUNK}"].find { |name| system("git", "rev-parse", "--verify", "--quiet", "#{name}^{commit}", out: File::NULL, err: File::NULL) }
end

def test_files_on_this_branch
  base, status = Open3.capture2("git", "merge-base", trunk.to_s, "HEAD", err: File::NULL)
  abort "Cannot tell where this branch left #{TRUNK}, so the work in hand is unknown. " \
        "Run inside a Git repository that has a #{TRUNK} branch (local or origin/#{TRUNK}), or use --all." unless status.success?
  changed, = Open3.capture2("git", "diff", "--name-only", "--relative", "--diff-filter=AMR", base.strip, "--", "test")
  untracked, = Open3.capture2("git", "ls-files", "--others", "--exclude-standard", "--", "test")
  (changed.lines + untracked.lines).map(&:chomp).grep(/_test\.rb\z/).select { |file| File.file?(file) }.uniq
end

all = ARGV.delete("--all")
files = all ? Dir["test/**/*_test.rb"] : test_files_on_this_branch
files = (files + ALWAYS.select { |f| File.file?(f) }).uniq unless all || ARGV.any? { |a| a.start_with?("-n") }
abort(all ? "No test files under test/." : "No test file is added or changed on this branch since it left #{TRUNK}; use --all for the whole suite.") if files.empty?

# The privacy check skips without the owner's denylist; say so here too, where every mode prints.
terms = ENV["PRIVATE_TERMS_FILE"].to_s
if files.any? { |f| f.end_with?("nothing_private_test.rb") } && (terms.empty? || !File.file?(terms))
  warn "!! PRIVATE_TERMS_FILE is unset or names no file: no tracked file is checked for private terms"
end

build = Target.path("bin/build")
if File.executable?(build)
  system(build, chdir: Target.root) or abort "bin/build in the work folder failed, so the tests did not run."
end

jobs = (ENV["JOBS"] || Etc.nprocessors).to_i.clamp(1, 16)
jobs = 1 unless Process.respond_to?(:fork)

if jobs == 1
  require_relative "test_helper"
  files.sort.each { |file| require File.join(shape, file) }
  # A run in which no test executed must not look like a pass.
  ran = 0
  Minitest::Test.prepend(Module.new { define_method(:before_setup) { ran += 1; super() } })
  Minitest.after_run do
    next unless ran.zero?
    $stdout.flush
    abort "\nNo tests ran, so this is not a pass. Check the -n filter you passed."
  end
  return
end

# The parent lists the tests and never runs one; the children, forked with everything loaded, run
# one each. Minitest's autorun is therefore not installed here.
verbose = !!(ARGV.delete("-v") || ARGV.delete("--verbose"))
take = lambda do |*names|
  names.each do |name|
    if (i = ARGV.index(name)) then ARGV.delete_at(i); return ARGV.delete_at(i) end
    if (a = ARGV.find { |x| x.start_with?("#{name}=") }) then ARGV.delete(a); return a.split("=", 2).last end
  end
  nil
end
matcher = ->(text) { text && (text =~ %r{\A/(.*)/\z} ? Regexp.new($1) : text) }   # as Minitest reads -n and -e
filter, exclude = matcher.(take.("-n", "--name")), matcher.(take.("-e", "--exclude"))
require "minitest"
Minitest.class_variable_set(:@@installed_at_exit, true)
require_relative "test_helper"
files.sort.each { |file| require File.join(shape, file) }
tests = Minitest::Runnable.runnables.select(&:name).flat_map { |klass| klass.public_instance_methods(true).grep(/\Atest_/).map(&:to_s).sort.map { |method| [klass, method] } }
tests.select! { |klass, method| filter === method || filter === "#{klass}##{method}" } if filter
tests.reject! { |klass, method| exclude === method || exclude === "#{klass}##{method}" } if exclude
abort "No tests ran, so this is not a pass. Check the -n filter you passed." if tests.empty?

seed = ENV.fetch("SEED") { rand(0xFFFF) }
puts "Run options: --seed #{seed}, #{jobs} processes\n\n# Running:\n\n"
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
pending = tests.shuffle(random: Random.new(seed.to_i))
running = {}
# Interrupted: each running test gets TERM and up to 3 s to kill what it started (detached processes
# included, see support/processes.rb); then its process group is killed.
trap("INT") do
  running.each_key { |pid| Process.kill("TERM", pid) rescue nil }
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
  left = running.keys
  until left.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    left.reject! { |pid| (Process.wait(pid, Process::WNOHANG) rescue pid) }
    sleep 0.05
  end
  running.each_key { |pid| Process.kill("KILL", -pid) rescue nil }
  exit 130
end
results = []
until pending.empty? && running.empty?
  while running.size < jobs && (test = pending.shift)
    klass, method = test
    out = Tempfile.new("report")
    pid = fork do
      Process.setpgid(0, 0) # one process group per test, killed below when the test has ended
      trap("TERM") { Thread.new { Processes.sweep(grace: 0); exit!(1) } } # the run was interrupted: end what this test started
      $stdout.reopen(out.path, "w"); $stderr.reopen($stdout)
      ok = Minitest.run(["-n", "#{klass}##{method}", "--seed", seed.to_s, *ARGV])
      $stdout.flush
      exit!(ok ? 0 : 1)   # exit!: the parent's at_exit hooks and temp files are not this process's to run or remove
    end
    running[pid] = [klass, method, out]
  end
  pid, status = Process.wait2
  Process.kill("KILL", -pid) rescue nil # whatever the test left in its group
  klass, method, out = running.delete(pid)
  text = File.read(out.path); out.close!
  mark = text[/# Running:\n\n(.)/, 1]
  mark = "E" unless mark && status.exited?
  mark = "E" unless %w[. F E S].include?(mark)
  took = text[/Finished in ([\d.]+)s/, 1] || "?"
  problem = text[/^  1\) .*?(?=\n\n\d+ runs, )/m] || (mark == "E" ? "  1) Error:\n#{klass}##{method}:\nThe process did not report; what it printed:\n#{text.gsub(/^/, "    ")}" : nil)
  counts = text.match(/(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips/)
  results << [klass, method, mark, problem, counts]
  if verbose then puts "#{klass}##{method} = #{took} s = #{mark}" else print mark; $stdout.flush end
end
seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)
puts "\n\nFinished in #{seconds}s, #{(results.size / seconds).round(4)} runs/s.\n\n"
results.select { |r| r[3] }.each_with_index do |(klass, method, mark, problem), i|
  puts problem.sub(/\A  1\) /, "  #{i + 1}) ") + "\n\n"
end
totals = %w[runs assertions failures errors skips].each_with_index.to_h { |k, i| [k, results.sum { |r| r[4] ? r[4][i + 1].to_i : 0 }] }
totals["runs"] += results.count { |r| r[4].nil? }
totals["errors"] += results.count { |r| r[2] == "E" && (r[4].nil? || r[4][4].to_i.zero?) }
puts "#{totals["runs"]} runs, #{totals["assertions"]} assertions, #{totals["failures"]} failures, #{totals["errors"]} errors, #{totals["skips"]} skips"
exit(results.all? { |r| %w[. S].include?(r[2]) } ? 0 : 1)
