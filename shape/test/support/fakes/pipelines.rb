# Extra Docker observations for pipeline tests. This does not decide a gate or pipeline result.
# Agent barriers and the fake PostgreSQL client hold two real gate subprocesses concurrently.
def pipeline_agent_barrier(play, record)
  name = play["barrier"]
  return unless name
  folder = File.join(JOURNAL, "barriers")
  FileUtils.mkdir_p(folder)
  File.write(File.join(folder, "#{name}.entered"), record["name"].to_s)
  deadline = Time.now + 90
  sleep 0.025 until File.exist?(File.join(folder, "#{name}.release")) || Time.now >= deadline
end

# Observe a Docker boundary before a checkout-volume create call returns. The opt-in barrier is
# consumed while holding the journal lock, then waits without it so status and crash recovery work.
def pipeline_checkout_volume_barrier(volume)
  return unless volume.match?(/\Ashop-run-\d{8}-\d{6}-[0-9a-f]{4}\z/)
  name = $state.delete("pipeline_checkout_volume_barrier")
  return unless name
  release_fake_state
  pipeline_agent_barrier({ "barrier" => name }, { "name" => volume })
  acquire_fake_state
end

def pipeline_record_compose(doc, project)
  # a verify's own sidecars (<service>-run-<id>-verify): kept, and unhealthy when the test said so
  if project.include?("-run-") && project.end_with?("-verify")
    members = containers.select { |_, container| container["project"] == project }
    members.each_value { |container| container["health"] = "unhealthy" } if $state["verify_unhealthy"]
    ($state["verify_projects"] ||= []) << JSON.parse(JSON.generate({ "project" => project, "document" => doc, "containers" => members }))
    return
  end
  return unless project.include?("-run-") && project.end_with?("-gate")
  members = containers.select { |_, container| container["project"] == project }
  members.each_value { |container| container["health"] = "unhealthy" } if $state["gate_unhealthy"]
  ($state["gate_projects"] ||= []) << JSON.parse(JSON.generate({ "project" => project, "document" => doc, "containers" => members }))
end

def pipeline_real_env(record)
  env = { "FAKE_GATE_NETWORKS" => JSON.generate(Array(record["networks"])),
          "FAKE_GATE_CONTAINER" => record["name"].to_s,
          "FAKE_DOCKER_JOURNAL" => JOURNAL }
  config = File.join(JOURNAL, "git-remotes.config")
  env["GIT_CONFIG_GLOBAL"] = config if File.exist?(config)
  env
end

# Who creates and removes a run's checkout volume (shop-run-<id>), in order: the farmy command line that ran
# this docker call (its parent process), so a test can tell the run itself from any other farmy process.
def pipeline_checkout_event(op, volume)
  return unless volume.match?(/\Ashop-run-\d{8}-\d{6}-[0-9a-f]{4}\z/)
  by = (File.read("/proc/#{Process.ppid}/cmdline").tr("\0", " ").strip rescue "?")
  ($state["checkout_events"] ||= []) << { "op" => op, "volume" => volume, "by" => by, "seq" => next_seq }
end

# Opt-in (hold_first_clone): the first docker call a run makes (from `farmy factory run <id>`) waits before it is
# carried out, until another process removes that run's checkout volume (shop-run-<id>), or 1 s at most. A process
# that cleans a run's resources while the run is starting is then always seen doing so.
def pipeline_hold_first_call_of_run
  return unless $state["hold_first_clone"]
  caller_line = (File.read("/proc/#{Process.ppid}/cmdline").tr("\0", " ") rescue "")
  run = caller_line[/factory run (\d{8}-\d{6}-[0-9a-f]{4})/, 1] or return
  seen = ($state["runs_first_call"] ||= [])
  return if seen.include?(run)
  seen << run
  volume = "shop-run-#{run}"
  removed = ->(state) { Array(state["checkout_events"]).any? { |e| e["volume"] == volume && e["op"] == "rm" && !e["by"].include?("factory run #{run}") } }
  release_fake_state
  deadline = Time.now + 1
  until Time.now >= deadline
    current = begin
      JSON.parse(File.read(STATE_FILE))
    rescue JSON::ParserError, Errno::ENOENT
      {}
    end
    break if removed.call(current)
    sleep 0.02
  end
  acquire_fake_state
end
