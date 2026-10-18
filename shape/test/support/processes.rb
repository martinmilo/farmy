# Every test ends every process it started. The process running a test makes itself the child
# subreaper (Linux prctl), so whatever its children start, even detached with setsid or double
# forks, is reparented to it rather than to PID 1. After teardown it finds those descendants,
# kills them, reaps them, and the test fails naming what was left behind.
module Processes
  PR_SET_CHILD_SUBREAPER = 36
  GRACE = 3 # seconds

  def self.available? = File.readable?("/proc/self/stat")

  def self.become_subreaper
    return if @subreaper == Process.pid || !available?
    require "fiddle"
    prctl = Fiddle::Function.new(Fiddle::Handle::DEFAULT["prctl"], [Fiddle::TYPE_INT, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG], Fiddle::TYPE_INT)
    @subreaper = Process.pid if prctl.call(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0).zero?
  end

  # [pid, state, command line] of every process below this one, zombies included.
  def self.descendants(root = Process.pid)
    rows = Dir.glob("/proc/[0-9]*/stat").filter_map do |path|
      stat = File.read(path) rescue next
      fields = stat[(stat.rindex(")") + 2)..].split
      pid = path[%r{/proc/(\d+)/}, 1].to_i
      [pid, fields[1].to_i, fields[0], stat[/\((.*)\)/m, 1]]
    end
    children = rows.group_by { |_, ppid| ppid }
    found, queue = [], [root]
    while (pid = queue.shift)
      (children[pid] || []).each do |child, _, state, comm|
        line = (File.read("/proc/#{child}/cmdline").tr("\0", " ").strip rescue "")
        found << [child, state, line.empty? ? comm : line]
        queue << child
      end
    end
    found
  end

  def self.reap
    loop { Process.wait(-1, Process::WNOHANG) or break }
  rescue Errno::ECHILD
  end

  # Kills and reaps everything below this process; returns the command lines that were still running.
  def self.sweep(grace: GRACE)
    return [] unless available?
    left = []
    # A process that ends by itself once teardown removed what it watched (the holder and its
    # socket) is not a leftover; give such processes a moment.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace
    loop do
      reap
      left = descendants.reject { |_, state| state == "Z" }
      break if left.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    50.times do
      alive = descendants.reject { |_, state| state == "Z" }
      break if alive.empty?
      alive.each { |pid, _| Process.kill("KILL", pid) rescue nil }
      sleep 0.02
      reap
    end
    reap
    left.map { |_, _, line| line }
  end

  def self.summary(lines)
    lines.group_by { |line| File.basename(line.split.first.to_s) }.sort_by { |name, all| [-all.size, name] }
         .map { |name, all| "  #{name} ×#{all.size}: #{all.first[0, 160]}" }.join("\n")
  end
end
