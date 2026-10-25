# What a played agent does in its container after its first writes (agent_plays' "steps"), in order:
#
#   {run: "<line>"}                    runs the line for real, as the agent's container would (agent_view below)
#   {run: "<line>", background: true} starts it and goes on; the agent waits for every such line before it ends
#   {writes: {path => text}}           writes files under /workspace as the play's writes do (none under a tmpfs)
#   {find: "<text>"}                   notes every file the container can see that holds the text
#   {list_writable: true}              notes every entry the container can see where it can write (agent_listing)
#   {sleep: <seconds>}
#
# Each run line's stdout and stderr (apart, and each chunk with the time it came), its exit code and when it started
# and ended are kept in state["agent_steps"]; a find keeps the container paths of the files holding its text. A line
# that printed more than LARGE_AGENT_OUTPUT keeps its stdout and stderr in two files instead ("stdout_file",
# "stderr_file"), and no chunks.
# The agent's `timeout <s>` covers its steps: at the limit every line still running is killed and the agent exits
# 124; stopping or removing its container kills them too (137).

AGENT_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" # Debian's, for a container that sets none
LARGE_AGENT_OUTPUT = 262_144 # bytes, stdout and stderr together

# Container path => host path, as the agent's container sees its files: each volume's folder, each bind's source,
# and for each --tmpfs a fresh empty folder that lasts as long as the container (a covered path reads empty).
def agent_view(record, mounts, tmpfs)
  table = {}
  mounts.each { |m| table[mount_target(m["target"])] = File.join(volume_dir(m["name"]), m["subpath"].to_s) }
  Array(record["binds"]).each { |b| table[mount_target(b["target"])] = File.expand_path(b["source"].to_s) }
  tmpfs.each do |t|
    target = mount_target(t["target"])
    table[target] = File.join(JOURNAL, "tmpfs", "agent-#{record["seq"]}#{target.tr("/", "-")}").tap { |d| FileUtils.mkdir_p(d) }
  end
  table
end

def mount_target(path) = path.to_s == "/" ? "/" : path.to_s.chomp("/")

# The container's environment and nothing else, its paths mapped; HOME a fresh folder unless it lies on a mount; PATH
# the container's own (Debian's when it sets none), mapped, behind a folder that holds every file bound or mounted
# into a folder on that PATH, so a program put there is found by its name. The image adds no file.
def agent_step_env(record, table)
  given = record["env"] || {}
  env = given.to_h { |k, v| [k, map_paths(v.to_s, table)] }
  dirs = (given["PATH"] || AGENT_PATH).split(":")
  shims = File.join(JOURNAL, "agent-path", record["seq"].to_s).tap { |d| FileUtils.mkdir_p(d) }
  table.each do |target, source|
    next unless dirs.include?(File.dirname(target)) && File.file?(source)
    link = File.join(shims, File.basename(target))
    File.symlink(source, link) unless File.symlink?(link)
  end
  home = given["HOME"] && env["HOME"] != given["HOME"] ? env["HOME"] : File.join(JOURNAL, "agent-home", record["seq"].to_s).tap { |d| FileUtils.mkdir_p(d) }
  env.merge("PATH" => ([shims] + dirs.map { |d| map_paths(d, table) }).join(":"), "HOME" => home, "LANG" => given.fetch("LANG", "C.UTF-8"))
end

def agent_write(table, tmpfs, writes)
  covered = tmpfs.map { |t| mount_target(t["target"]) }
  work = table["/workspace"] or return
  (writes || {}).each do |path, text|
    full = "/workspace/#{path}"
    next if covered.any? { |c| full == c || full.start_with?("#{c}/") } # under a tmpfs: lands nowhere that lasts
    file = File.join(work, path)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, text)
  end
end

# Every file the container can see that holds the text, by its path in the container. A file is seen through the
# most specific mount over its path, so what lies under a tmpfs in a volume's folder is not seen.
def agent_find(table, text)
  found = []
  table.each do |target, source|
    next unless File.exist?(source)
    files = File.file?(source) ? [[target, source]] : Dir.glob(File.join(source, "**", "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) }.map { |f| [File.join(target, f.delete_prefix(source).delete_prefix("/")), f] }
    files.each do |path, file|
      seen_through = table.keys.select { |t| path == t || path.start_with?("#{t}/") }.max_by(&:length)
      next unless seen_through == target
      found << path if (File.binread(file).include?(text.b) rescue false)
    end
  end
  found.uniq.sort
end

# The container paths it can write: its volumes and binds not mounted read-only, its tmpfs not ro.
def agent_writable(record, mounts, tmpfs)
  (mounts.reject { |m| m["ro"] }.map { |m| m["target"] } +
   Array(record["binds"]).reject { |b| b["ro"] }.map { |b| b["target"] } +
   tmpfs.reject { |t| t["options"].to_s.split(",").include?("ro") }.map { |t| t["target"] }).map { |t| mount_target(t) }
end

# Every entry (file, folder, link, FIFO) the container can see under a path it can write, by its path in the
# container. An entry is seen through the most specific mount over it, so what lies under a read-only one (the
# workspace's .git, a hidden folder) is not listed.
def agent_listing(table, writable)
  listed = []
  table.each do |target, source|
    next unless writable.include?(target) && File.directory?(source)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: source).each do |relative|
      next if relative.split("/").any? { |part| part == "." || part == ".." }
      path = File.join(target, relative)
      seen_through = table.keys.select { |t| path == t || path.start_with?("#{t}/") }.max_by(&:length)
      listed << path if seen_through == target
    end
  end
  listed.uniq.sort
end

def agent_container_running?(name)
  c = (JSON.parse(File.read(STATE_FILE))["containers"][name] rescue :unreadable)
  c == :unreadable || (c && c["state"] == "running")
end

def start_agent_line(line, env, cwd, table)
  out_r, out_w = IO.pipe
  err_r, err_w = IO.pipe
  started = Time.now.to_f
  pid = Process.spawn(env, "/bin/sh", "-c", map_paths(line, table), chdir: cwd, unsetenv_others: true,
                      in: File::NULL, out: out_w, err: err_w, pgroup: true)
  out_w.close
  err_w.close
  chunks = []
  guard = Mutex.new
  readers = { "stdout" => out_r, "stderr" => err_r }.map do |stream, io|
    Thread.new do
      loop do
        text = io.readpartial(65_536)
        guard.synchronize { chunks << { "at" => Time.now.to_f, "stream" => stream, "text" => text.force_encoding(Encoding::UTF_8).scrub } }
      end
    rescue EOFError, IOError
      nil
    ensure
      io.close unless io.closed?
    end
  end
  { "line" => line, "pid" => pid, "started" => started, "chunks" => chunks, "readers" => readers, "guard" => guard }
end

# Waits for a line until it ends, the agent's limit passes or its container is stopped. Returns nil, or the agent's
# exit code (124, 137) when the agent ends there.
def wait_agent_line(job, deadline, record, index)
  ended_by = nil
  status = nil
  loop do
    if Process.wait(job["pid"], Process::WNOHANG)
      status = $?.exitstatus || (128 + $?.termsig.to_i)
      break
    end
    ended_by = 124 if deadline && Time.now >= deadline
    ended_by ||= 137 unless agent_container_running?(record["name"])
    if ended_by
      Process.kill("KILL", -job["pid"]) rescue nil
      Process.wait(job["pid"]) rescue nil
      status = 137
      break
    end
    sleep 0.05
  end
  job["readers"].each { |t| t.join(2) }
  chunks = job["guard"].synchronize { job["chunks"].dup }
  step = { "run" => job["line"], "exit" => status, "started_at" => job["started"], "ended_at" => Time.now.to_f, "killed" => !ended_by.nil? }
  streams = %w[stdout stderr].to_h { |s| [s, chunks.select { |c| c["stream"] == s }.map { |c| c["text"] }.join] }
  if streams.values.sum(&:bytesize) > LARGE_AGENT_OUTPUT
    folder = File.join(JOURNAL, "agent-output").tap { |d| FileUtils.mkdir_p(d) }
    streams.each do |stream, text|
      step["#{stream}_file"] = File.join(folder, "#{record["seq"]}-#{index}.#{stream}").tap { |f| File.binwrite(f, text) }
    end
  else
    step.merge!(streams, "chunks" => chunks)
  end
  keep_agent_step(record, index, step)
  ended_by
end

def keep_agent_step(record, index, step)
  acquire_fake_state
  ($state["agent_steps"] ||= []) << { "container" => record["name"], "iteration" => record["labels"]["farmy.iteration"],
                                       "run_id" => record["labels"]["farmy.run"], "index" => index }.merge(step)
  release_fake_state
end

# Plays the steps with the journal unlocked (what they run may call docker). Returns nil, or the exit code the agent
# ends with when its limit passed or its container was stopped during a step.
def play_agent_steps(play, opts, record, mounts, tmpfs, deadline)
  steps = Array(play["steps"])
  return nil if steps.empty?
  table = agent_view(record, mounts, tmpfs)
  env = agent_step_env(record, table)
  workdir = value(opts, "w", "workdir") || "/workspace"
  cwd = map_paths(workdir, table)
  cwd = JOURNAL unless File.directory?(cwd)
  waiting = []
  steps.each_with_index do |step, i|
    index = i + 1
    if step["run"]
      job = start_agent_line(step["run"].to_s, env, cwd, table)
      if step["background"] then waiting << [job, index]
      elsif (ended = wait_agent_line(job, deadline, record, index))
        waiting.each { |j, _| Process.kill("KILL", -j["pid"]) rescue nil }
        waiting.each { |j, n| wait_agent_line(j, deadline, record, n) }
        return ended
      end
    elsif step["writes"] then agent_write(table, tmpfs, step["writes"])
    elsif step["find"] then keep_agent_step(record, index, "find" => step["find"].to_s, "found" => agent_find(table, step["find"].to_s))
    elsif step["list_writable"]
      keep_agent_step(record, index, "listing" => agent_listing(table, agent_writable(record, mounts, tmpfs)), "at" => Time.now.to_f)
    elsif step["sleep"] then sleep step["sleep"].to_f
    end
  end
  ended = nil
  waiting.each { |job, index| ended = wait_agent_line(job, deadline, record, index) || ended }
  ended
end
