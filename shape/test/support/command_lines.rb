# Secrets and command lines: what every process farmy starts shows in its argv while a run goes, and the
# env files farmy hands Docker (the fake docker notes each --env-file it read: its path and mode).
#
#   secret_value "sk-ant-oat01"          a value unique to this test, so no other test's processes can show it
#   watch_command_lines { … }            samples every process's command line on the machine (ps) while the block
#                                        runs, and marks where the docker call log stood when it began
#   assert_no_command_line_holds "CLAUDE_CODE_OAUTH_TOKEN", value   neither a docker call made since the mark
#                                        nor a sampled process held the value
#   run_env_files                        the --env-file files Docker read for the run's containers: [{path, mode}]
#   assert_env_files_private_and_gone    each was mode 600 when read and no longer exists
#   refute_under_work value              no file under .work holds the value
#   refute_in_files_farmy_wrote value    no file farmy writes in the containers folder (.work/, .env) holds it
#   assert_compose_names_without_value "shop", "CLAUDE_CODE_OAUTH_TOKEN"   .work/shop/compose.yml gives the app the variable by name only
require "securerandom"

module CommandLines
  def secret_value(prefix) = "#{prefix}-#{SecureRandom.hex(8)}"

  def watch_command_lines
    @calls_mark = docker_calls.size
    @sampled_command_lines = []
    stop = false
    watcher = Thread.new do
      until stop
        out, = Open3.capture2("ps", "-A", "-o", "args=") rescue [""]
        @sampled_command_lines.concat(out.lines(chomp: true))
        @sampled_command_lines.uniq!
        sleep 0.02
      end
    end
    yield
  ensure
    stop = true
    watcher&.join
  end

  def assert_no_command_line_holds(name, value)
    calls = docker_calls.drop(@calls_mark.to_i).select { |l| l.include?(value) }.map { |l| "docker #{l}" }
    sampled = Array(@sampled_command_lines).select { |l| l.include?(value) }
    holding = (calls + sampled).uniq
    assert holding.empty?, "Expected no process farmy started during the run to hold the value of #{name} on its command line " \
      "(Docker can take it as -e #{name} without a value, from the environment farmy gives the docker process, or from a " \
      "0600 --env-file deleted once the container has started); these did:\n  #{holding.join("\n  ")}\n\n#{docker_situation}#{transcript}"
  end

  def run_env_files
    run_containers_with_env_files.flat_map { |r| Array(r["env_files"]) }
  end

  def assert_env_files_private_and_gone
    run_containers_with_env_files.each do |r|
      Array(r["env_files"]).each do |f|
        assert_equal "600", f["mode"], "Expected the env file #{f["path"]} that Docker read for #{r["name"]} to be readable and writable by its owner only (mode 600); it was #{f["mode"]}.#{transcript}"
        refute File.exist?(f["path"]), "Expected the env file #{f["path"]} for #{r["name"]} to be deleted once the container had started, while it still runs; it is still there.#{transcript}"
      end
    end
  end

  def refute_under_work(value)
    holding = Dir.glob(File.join(dir, ".work", "**", "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) && File.read(f).include?(value) }
    assert holding.empty?, "Expected no file under .work to hold the secret's value; it is in #{holding.map { |f| f.delete_prefix("#{dir}/") }.join(", ")}.#{transcript}"
  end

def refute_in_files_farmy_wrote(value)
  files = Dir.glob(File.join(dir, ".work", "**", "*"), File::FNM_DOTMATCH) + [File.join(dir, ".env")]
  holding = files.select { |f| File.file?(f) && File.binread(f).include?(value) }
  assert holding.empty?, "Expected no file farmy writes in the containers folder (under .work/, or .env) to hold the secret's value; it is in #{holding.map { |f| f.delete_prefix("#{dir}/") }.join(", ")}. A compose file can name the variable (environment: [NAME], or NAME: ${NAME}) and farmy give the value in the environment of docker compose.#{transcript}"
end

def assert_compose_names_without_value(service, name)
  file = File.join(dir, ".work", service, "compose.yml")
  assert File.file?(file), "Expected .work/#{service}/compose.yml.#{transcript}"
  doc = YAML.safe_load(File.read(file), aliases: true) || {}
  app = (doc["services"] || {}).values.find { |s| (e = s["environment"]) && (e.is_a?(Hash) ? e.key?(name) : e.any? { |x| x.to_s.split("=", 2).first == name }) }
  assert app, "Expected an app service in .work/#{service}/compose.yml with #{name} under environment:.#{transcript}"
  e = app["environment"]
  given = e.is_a?(Hash) ? e[name] : (e.find { |x| x.to_s.split("=", 2).first == name }.to_s.split("=", 2)[1])
  assert given.nil? || ["${#{name}}", "$#{name}"].include?(given.to_s), "Expected .work/#{service}/compose.yml to give #{name} by name only (environment: [#{name}], or #{name}: ${#{name}}), its value coming from the environment of docker compose; it gives #{given.to_s[0, 12].inspect}….#{transcript}"
end

  private

  def docker_calls
    calls = File.join(docker_journal, "calls.log")
    File.exist?(calls) ? File.readlines(calls, chomp: true) : []
  end

  def run_containers_with_env_files
    docker_state["runs"].select { |r| !(r["labels"] || {})["farmy.run"].to_s.empty? && !Array(r["env_files"]).empty? }
  end
end
