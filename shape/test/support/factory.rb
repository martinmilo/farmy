# The factory: runs of an agent against a separate gate. The fake docker runs the git and test containers
# for real on a folder per volume and plays the agent as the test says (FORMATS.md, "Docker in the tests").
#
#   factory_service protects: ["test/"], max_iterations: 3   shop on the test's git host (src/app.txt "broken",
#                                       test/check.sh passes when src/app.txt says fixed), commands.test: sh test/check.sh,
#                                       factory: in its definition, claude in api-key mode; started, its key held
#   factory_service verify: "test", sidecar: :health_checked   factory.verify names that command; the postgres sidecar has a healthcheck
#   with_ssh_git_route                  an SSH git route for github.com too, its key given, shop made anew
#   with_mesh_egress                    mesh egress in farmy.yml too, joined with an auth key, shop made anew
#   assert_gate_reaches "shop-pg", as: "postgres"   the gate is on an internal network of the run, which the sidecar joined under that name
#   refute_sidecar_joins · assert_run_git_config "git", "core.sshCommand", /nc -X 5/
#   checkout_owned_by 0 · assert_run_user "git", 1001 · assert_volume_owner "shop-run-<id>", 1001 · run_git_log
#   factory_service model: :token, egress: true   Claude through its token (no anthropic route), with mesh egress
#   factory_service model: :token, token: "sk-ant-oat01-…"   the values given to start: token, api_key, authkey (defaults fixed)
#   run_networks "agent"                the networks the role's containers were on
#   agent_plays {writes: {"src/app.txt" => "fixed\n"}}, {says: "done", exit: 1}, {idle: 5}   what the agent does, iteration by iteration
#   factory_start task: "…", wait: true   farmy factory start shop --task … [--wait]
#   run_id                              the run id in the last output
#   assert_pushed "farmy/shop/<id>", commits: ["farmy: iteration 1", …]   the branch on the git host, its commits above main
#   refute_pushed                       no farmy/ branch on the git host
#   assert_checkout_unchanged           the developer's checkout (shop-src) is on main at the remote's commit, no farmy/ branch
#   run_file id, "test/check.sh"        a file at the tip of the run branch in the run volume
#   run_containers "agent"              the docker runs of a role, in order
#   assert_covered "agent", "/workspace/.git"   every container of the role has an empty tmpfs there
#   agent_prompts                       what each agent was given as its prompt (stdin, else its last word)
#   fail_role "test"                    Docker refuses to start that role's containers
#   wait_for_agent · kill_controller id the detached controller: wait until an agent runs; kill it and its children
#   agent_record 1                      iteration 1's iteration-1.agent.json of the last run, parsed
#   run_record_text "iteration-1.prompt.md"   a file of the last run's folder, as written
#   run_state                           the last run's state.json, parsed
#   run_agent_config                    its agent_config: the agent entry the run used, resolved
#   assert_run_keeps_no_version         its state.json has agent_version, and it is null
#   image_id_of "farmy/shop:dev"        the id docker image inspect gives that image (sha256:…)
#   assert_utc_timestamp value, "started"   RFC 3339 in UTC, 2026-10-18T20:16:05Z
#   refute_in_run_folder value          no file of the last run's folder holds the value
#   agent_version_prints "2.1.40 (Claude Code)" · agent_version_fails · agent_version_denied · agent_version_hangs   what the run's version container answers
#   assert_version_unknown_because "126", "Permission denied"   agent_version unknown, the reason giving the exit code and the last stderr line
#   assert_recorded_command_is_exactly_the_agents_docker_call 1   the record's command is, word for word, the docker run of that agent (docker's call log)
#   assert_version_asked_once_with "claude --version"   one version container: farmy/shop:dev, user dev, --network none, that line
#   mytool_agent(version: "mytool --version", factory_login: "{path: .mytool, create: …}")   farmy.yml lines for an agent of your own, mytool: headless on stdin, Claude's token as its token_env
module Factory
  def factory_service(protects: ["test/"], hidden: nil, writes: nil, max_iterations: 3, iteration_timeout: "30m", agent: "claude", test: "test",
                      check: "grep -q fixed src/app.txt\n", files: {}, gate: nil, sidecar: false, model: :api, egress: false,
                      profiles: nil, commands: {}, extra_config: "", verify: nil,
                      token: "sk-ant-oat01-9f2c", api_key: "sk-ant-api03-4f9e", authkey: "tskey-auth-k9f2c1e5d7b")
    settings
    remote_repository "acme/shop", **{ "src/app.txt" => "broken\n", "test/check.sh" => check, "README.md" => "# shop\n" }.merge(files)
    block = { "base" => "main", "agent" => agent, "writes" => writes, "protects" => protects, "hidden" => hidden,
              "test" => test, "verify" => verify, "max_iterations" => max_iterations, "iteration_timeout" => iteration_timeout, "gate" => gate }.compact
    block = profiles if profiles
    # sidecar: true, a postgres; :health_checked, the same with a healthcheck (pg_isready)
    postgres = { "image" => "postgres:18", "container_name" => "shop-pg" }
    postgres["healthcheck"] = { "test" => ["CMD", "pg_isready"], "interval" => "1s", "retries" => 1 } if sidecar == :health_checked
    fragment = sidecar ? { "compose" => { "postgres" => postgres } } : {}
    write_file "services/shop.yml", YAML.dump({ "repo" => remote_url("acme/shop"), "image" => "debian:bookworm-slim",
                                              "commands" => { "test" => "sh test/check.sh" }.merge(commands),
                                              "factory" => block }.merge(fragment)).delete_prefix("---\n")
    # api: an anthropic route, the key held; token: no route, the env provider and Claude's token_env from an unlocking value
    api_mode, token_mode = model != :token, model != :api
    unlock = (token_mode ? ["CLAUDE_CODE_OAUTH_TOKEN"] : []) + (egress ? ["TS_AUTHKEY"] : [])
    yml = +""
    yml << "secrets:\n" << (token_mode ? "  provider: [providers/env]\n" : "") << "  unlock: [#{unlock.join(", ")}]\n" unless unlock.empty?
    yml << "keys:\n  anthropic:\n    secret: ANTHROPIC_API_KEY\n    upstream: https://api.anthropic.com\n    auth: header\n    header: x-api-key\n" if api_mode
    yml << "egress:\n  authkey: TS_AUTHKEY\n" if egress
    yml << extra_config
    write_file "farmy.yml", yml
    values = { "ANTHROPIC_API_KEY" => (api_mode ? api_key : nil), "CLAUDE_CODE_OAUTH_TOKEN" => (token_mode ? token : nil),
               "TS_AUTHKEY" => (egress ? authkey : nil) }.compact
    note_situation "The service definition uses named factory profiles:\n#{read_file("services/shop.yml")}" if profiles
    farmy "start", "shop", stdin: values.map { |k, v| "#{k}=#{v}\n" }.join
    assert finished.exit.zero?, "Expected farmy start shop to succeed with factory: in its definition (the run clones its checkout), and it did not.#{transcript}"
    note_situation "shop: src/app.txt says broken; its test (sh test/check.sh) passes once src/app.txt says fixed. factory: #{block.map { |k, v| "#{k} #{v}" }.join(", ")}. Model access: #{model == :api ? "api-key mode, an anthropic route" : "token mode, CLAUDE_CODE_OAUTH_TOKEN"}#{", mesh egress" if egress}. Started; the values held."
  end

  # An SSH git route in farmy.yml, the key given, the service made anew with it.
  def with_ssh_git_route
    write_file "farmy.yml", read_file("farmy.yml") + "  git:\n    secret: GIT_SSH_KEY\n    upstream: ssh://git@github.com\n    auth: ssh\n    git: true\n"
    farmy "restart", "shop", stdin: "GIT_SSH_KEY:base64=#{[fixture("keys/git_ed25519")].pack("m0")}\n"
    assert finished.exit.zero?, "Expected farmy restart shop to succeed with an SSH git route added, and it did not.#{transcript}"
    note_situation "farmy.yml also has an SSH git route for github.com, its key given."
  end

  def with_mesh_egress
    write_file "farmy.yml", "secrets:\n  unlock: [TS_AUTHKEY]\n#{read_file("farmy.yml")}egress:\n  authkey: TS_AUTHKEY\n"
    farmy "restart", "shop", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"
    assert finished.exit.zero?, "Expected farmy restart shop to succeed with mesh egress added, and it did not.#{transcript}"
    note_situation "farmy.yml also has mesh egress, joined with an auth key."
  end
  
  # The test container's network, and the internal network the run made for the gate: the sidecars that joined it, under which names.
  def assert_gate_reaches(container, as:)
    gate_net = run_containers("test").flat_map { |r| Array(r["networks"]) }.uniq
    made = Array(docker_state["networks_made"]).select { |n| n["internal"] }.map { |n| n["name"] }
    assert gate_net.size == 1 && made.include?(gate_net.first), "Expected the gate on one internal network the run made (docker network create --internal); it is on #{gate_net.empty? ? "none given" : gate_net.join(", ")}, and the internal networks made are #{made.empty? ? "none" : made.join(", ")}.#{transcript}"
    joined = Array(docker_state["network_joins"]).select { |j| j["action"] == "connect" && j["network"] == gate_net.first && j["container"] == container }
    assert joined.any? { |j| j["aliases"].include?(as) }, "Expected #{container} to join #{gate_net.first} under the name #{as} (docker network connect --alias #{as}); joins: #{Array(docker_state["network_joins"]).map { |j| "#{j["action"]} #{j["container"]} #{j["network"]} #{j["aliases"].join(",")}" }.join("; ").then { |x| x.empty? ? "none" : x }}.#{transcript}"
  end
  
  def refute_sidecar_joins
    joins = Array(docker_state["network_joins"]).select { |j| j["action"] == "connect" && j["network"].end_with?("-gate") }
    assert joins.empty?, "Expected no sidecar to join a gate network of the run; #{joins.map { |j| "#{j["container"]} joined #{j["network"]}" }.join(", ")}.#{transcript}"
  end
  
  # A git setting the role's containers are given (GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n, or -c on the command).
  def assert_run_git_config(role, key, value)
    run_containers(role).each do |r|
      pairs = r["env"].select { |k, _| k.start_with?("GIT_CONFIG_KEY_") }.to_h { |k, v| [v, r["env"]["GIT_CONFIG_VALUE_#{k.delete_prefix("GIT_CONFIG_KEY_")}"]] }
      assert value === pairs[key].to_s, "Expected the #{role} container #{r["name"]} to give git #{key} = #{value.inspect}; it gives #{pairs.map { |k, v| "#{k}=#{v}" }.join(", ").then { |x| x.empty? ? "no git settings" : x }}.#{transcript}"
    end
  end
  
# The developer's checkout belongs to another user than the toolbox's dev (uid 1001).
    def checkout_owned_by(uid)
      change_docker_state { |s| s["volumes"]["shop-src"]["owner"] = uid.to_s }
      note_situation "The checkout volume shop-src belongs to uid #{uid}."
    end

    def assert_run_user(role, uid)
      runs = run_containers(role)
      assert !runs.empty?, "Expected #{role} containers in the run.#{transcript}"
      runs.each do |r|
        user = r["user"].to_s.split(":").first.to_s
        have = { "" => "0", "root" => "0", "dev" => "1001" }.fetch(user, user)
        assert have == uid.to_s, "Expected the #{role} container #{r["name"]} to run as uid #{uid} (the checkout's owner, the toolbox's dev user); it runs as #{r["user"].inspect}.#{transcript}"
      end
    end

    def assert_volume_owner(volume, uid)
      owner = (docker_state["volumes"][volume] || {})["owner"]
      assert owner == uid.to_s, "Expected the volume #{volume} to belong to uid #{uid} (made so with chown by root before git writes into it); it belongs to #{owner.inspect}.#{transcript}"
    end

    # The git log of the one run of the test, which farmy keeps even when start refuses.
    def run_git_log
      logs = Dir.glob(File.join(dir, ".work", "shop", "runs", "*", "git.log"))
      assert logs.size == 1, "Expected the run's git output in .work/shop/runs/<id>/git.log; found #{logs.empty? ? "none" : logs.map { |l| l.delete_prefix("#{dir}/") }.join(", ")}.#{transcript}"
      File.read(logs.first)
    end

    def run_networks(role) = run_containers(role).flat_map { |r| Array(r["networks"]) }.uniq

  def agent_plays(*plays)
    change_docker_state { |s| ((s["agent_plays"] ||= {})["shop"] ||= []).concat(plays.map { |p| JSON.parse(JSON.generate(p)) }) }
    note_situation "The agent, iteration by iteration: #{plays.map(&:inspect).join(" | ")}."
  end

  def factory_start(task: "Make the check pass.", wait: true, stdin: "", profile: nil, from: nil)
    farmy "factory", "start", "shop", "--task", task, *(profile ? ["--profile", profile] : []),
          *(from ? ["--from", from] : []), *(wait ? ["--wait"] : []), stdin: stdin
    (@run_ids ||= []) << run_id if run_id
  end

  def run_id = (stdout + stderr)[/\b\d{8}-\d{6}-[0-9a-f]{4}\b/]

  def assert_pushed(branch, commits:)
    log = host_git("log", "--format=%s", "main..#{branch}")
    assert log, "Expected the branch #{branch} on the git host; it has: #{host_git("branch", "--format=%(refname:short)").to_s.split.join(", ")}.#{transcript}"
    assert_equal commits, log.lines(chomp: true).reverse, "Expected the commits of #{branch} above main, oldest first."
  end

  def refute_pushed
    branches = host_git("branch", "--format=%(refname:short)").to_s.split
    assert branches.none? { |b| b.start_with?("farmy/") }, "Expected no farmy/ branch on the git host; it has #{branches.join(", ")}.#{transcript}"
  end

  def assert_checkout_unchanged
    dir = volume_folder("shop-src")
    head = local_git(dir, "rev-parse", "--abbrev-ref", "HEAD").to_s.strip
    assert_equal "main", head, "Expected the developer's checkout (shop-src) to stay on main."
    assert_equal host_git("rev-parse", "main").to_s.strip, local_git(dir, "rev-parse", "HEAD").to_s.strip, "Expected the developer's checkout at the remote's main."
    branches = local_git(dir, "branch", "--format=%(refname:short)").to_s.split
    assert branches.none? { |b| b.start_with?("farmy/") }, "Expected no farmy/ branch in the developer's checkout; it has #{branches.join(", ")}."
  end

  def run_file(id, path)
    local_git(volume_folder("shop-run-#{id}"), "show", "farmy/shop/#{id}:#{path}")
  end

  def run_containers(role)
    docker_state["runs"].select do |r|
      labels = r["labels"] || {}
      labels["farmy.role"] == role && !labels["farmy.run"].to_s.empty?
    end
  end

  def assert_covered(role, target)
    runs = run_containers(role)
    assert !runs.empty?, "Expected #{role} containers in the run.\n\n#{docker_situation}#{transcript}"
    runs.each do |r|
      assert Array(r["tmpfs"]).any? { |t| t["target"] == target }, "Expected the #{role} container #{r["name"]} to cover #{target} with an empty tmpfs (--tmpfs #{target}:ro); its tmpfs: #{Array(r["tmpfs"]).map { |t| t["target"] }.join(", ").then { |x| x.empty? ? "none" : x }}.#{transcript}"
    end
  end

  def assert_run_mount(role, volume, at:, readonly:)
    run_containers(role).each do |r|
      m = Array(r["mounts"]).find { |x| x["target"] == at }
      assert m && m["name"] == volume, "Expected the #{role} container #{r["name"]} to mount #{volume} at #{at}; it mounts #{Array(r["mounts"]).map { |x| "#{x["name"]} at #{x["target"]}" }.join(", ")}.#{transcript}"
      assert m["ro"] == readonly, "Expected #{volume} in the #{role} container #{r["name"]} to be #{readonly ? "read-only (:ro)" : "writable"}.#{transcript}"
    end
  end

  def refute_run_volume(role, volume)
    run_containers(role).each do |r|
      assert !Array(r["volumes"]).include?(volume), "Expected the #{role} container #{r["name"]} without the volume #{volume}; it has it.#{transcript}"
    end
  end

  def assert_run_env(role, key, value = nil)
    runs = run_containers(role)
    assert !runs.empty?, "Expected #{role} containers in the run.\n\n#{docker_situation}#{transcript}"
    runs.each do |r|
      assert r["env"].key?(key), "Expected the #{role} container #{r["name"]} to have #{key} in its environment; it has #{r["env"].keys.sort.join(", ")}.#{transcript}"
      assert value === r["env"][key], "Expected #{key} in the #{role} container #{r["name"]} to be #{value.inspect}, got #{r["env"][key].inspect}.#{transcript}" if value
    end
  end

  def refute_run_env(role, key)
    run_containers(role).each do |r|
      assert !r["env"].key?(key), "Expected the #{role} container #{r["name"]} without #{key} in its environment; it has #{key}=#{r["env"][key]}.#{transcript}"
    end
  end

  def agent_prompts
    run_containers("agent").map { |r| r["stdin"].to_s.empty? ? r["process"].last.to_s : r["stdin"] }
  end

  def fail_role(role)
    change_docker_state { |s| (s["fail_roles"] ||= []) << role }
    note_situation "Docker refuses to start the run's #{role} containers."
  end

  def wait_for_agent
    deadline = Time.now + 20
    sleep 0.1 until run_containers("agent").any? || Time.now > deadline
    assert run_containers("agent").any?, "Expected an agent container to be running within 20 s of factory start.\n\n#{docker_situation}#{transcript}"
  end

  def kill_controller(id)
    pid = `pgrep -f "factory run #{id}"`.split.first or flunk("Expected a controller process (farmy factory run #{id}) to be running; there is none.#{transcript}")
    group = Process.getpgid(pid.to_i) rescue nil
    Process.kill("KILL", -group) rescue Process.kill("KILL", pid.to_i)
    sleep 0.2
    note_situation "The controller of #{id} was killed."
  end

  def agent_record(iteration)
    JSON.parse(run_record_text("iteration-#{iteration}.agent.json"))
  rescue JSON::ParserError => e
    flunk "Expected iteration-#{iteration}.agent.json in the run's folder to be a JSON object; it does not parse (#{e.message}).#{transcript}"
  end

  def run_record_text(name)
    folder = File.join(dir, ".work", "shop", "runs", run_id.to_s)
    file = File.join(folder, name)
    have = Dir.exist?(folder) ? Dir.children(folder).sort.join(", ") : "no folder .work/shop/runs/#{run_id}"
    assert File.file?(file), "Expected #{name} in the run's folder .work/shop/runs/#{run_id}/; it has: #{have}.#{transcript}"
    File.read(file)
  end

  def run_state = JSON.parse(run_record_text("state.json"))

  def run_agent_config
    config = run_state["agent_config"]
    assert config.is_a?(Hash), "Expected state.json to keep agent_config, the agent entry the run used (catalogue entry with farmy.yml's overrides, plus its name), next to profile_config; it has: #{run_state.keys.sort.join(", ")}.#{transcript}"
    config
  end

  def assert_run_keeps_no_version
    assert run_state.key?("agent_version"), "Expected state.json to have agent_version (null when the agent has no version command, or the command succeeded and printed nothing); it has: #{run_state.keys.sort.join(", ")}.#{transcript}"
    assert_nil run_state["agent_version"], "Expected agent_version null in state.json."
  end

  def image_id_of(tag) = "sha256:#{Digest::SHA256.hexdigest(tag)}"

  def assert_utc_timestamp(value, what)
    assert value.to_s.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/), "Expected #{what} as RFC 3339 in UTC (2026-10-18T20:16:05Z); it is #{value.inspect}.#{transcript}"
  end

  def refute_in_run_folder(value)
    folder = File.join(dir, ".work", "shop", "runs", run_id.to_s)
    holding = Dir.glob(File.join(folder, "**", "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) && File.read(f).include?(value) }
    assert holding.empty?, "Expected #{value.inspect} in no file of the run's folder; it is in #{holding.map { |f| File.basename(f) }.join(", ")}.#{transcript}"
  end

  def agent_version_prints(text)
    change_docker_state { |s| (s["agent_version_prints"] ||= {})["shop"] = text }
    note_situation "The CLI in shop's image prints #{text.inspect} when asked its version."
  end

  def agent_version_hangs
    change_docker_state { |s| (s["agent_version_hangs"] ||= []) << "shop" }
    note_situation "The version command in shop's image never answers: it runs silent until stopped (or 120 s)."
  end

  def agent_version_fails
    change_docker_state { |s| (s["agent_version_fails"] ||= []) << "shop" }
    note_situation "The version command fails in shop's image: sh says the command is not found, exit 127."
  end

  def agent_version_denied
    change_docker_state { |s| (s["agent_version_denied"] ||= []) << "shop" }
    note_situation "The CLI in shop's image cannot be executed by dev: sh says Permission denied, exit 126."
  end

  def assert_version_unknown_because(*words)
    assert_equal "unknown", run_state["agent_version"], "Expected agent_version \"unknown\" in state.json when the version command failed.#{transcript}"
    reason = run_state["agent_version_reason"].to_s
    words.each { |w| assert_includes reason, w, "Expected agent_version_reason in state.json to give the version command's exit code and the last line it wrote to stderr (here #{words.join(", ")}); it is #{run_state["agent_version_reason"].inspect}.#{transcript}" }
  end

  def assert_recorded_command_is_exactly_the_agents_docker_call(iteration)
    run = run_containers("agent").find { |r| r["name"].to_s.end_with?("-agent-#{iteration}") } or flunk("Expected an agent container for iteration #{iteration}.#{transcript}")
    calls = docker_call_words
    call = calls.find { |w| w.first == "run" && w.each_cons(2).include?(["--name", run["name"]]) } or flunk("Expected a docker run naming #{run["name"]} in docker's call log.#{transcript}")
    command = agent_record(iteration)["command"]
    assert_equal ["docker"] + call, command, "Expected iteration-#{iteration}.agent.json's command to be, word for word, the docker run farmy made for #{run["name"]}, starting \"docker\", \"run\" (no secret's value is on it to replace)."
  end
  
  def assert_version_asked_once_with(line)
    runs = run_containers("version")
    assert runs.size == 1, "Expected one container labelled farmy.role=version in the run, asking the CLI's version; there are #{runs.size}.\n\n#{docker_situation}#{transcript}"
    r = runs.first
    assert_equal "farmy/shop:dev", r["image"], "Expected the version container to run the service image."
    assert_equal ["none"], Array(r["networks"]), "Expected the version container without a network (--network none)."
    assert_equal "dev", r["user"].to_s.split(":").first, "Expected the version container to run as dev (-u dev)."
    assert Array(r["process"]).include?(line), "Expected the version container to run #{line.inspect} (sh -c #{line}); its process is #{Array(r["process"]).inspect}.#{transcript}"
  end

  def mytool_agent(version: nil, factory_login: nil)
    "agents:\n  mytool:\n    install: null\n    login: null\n    headless_login: null\n" \
      "    headless: {command: mytool run --yes, prompt: stdin}\n    token_env: CLAUDE_CODE_OAUTH_TOKEN\n" \
      "    api_hosts: ['api.mytool.example:443']\n#{version ? "    version: #{version}\n" : ""}#{factory_login ? "    factory_login: #{factory_login}\n" : ""}"
  end

  def after_teardown
    Array(@run_ids).compact.each { |id| `pgrep -f "factory run #{id}"`.split.each { |pid| (Process.kill("KILL", -Process.getpgid(pid.to_i)) rescue nil) } }
    super
  end

  # Every docker call in the call log, as its words (a call whose words hold a newline spans several lines).
  def docker_call_words
    buffer = nil
    File.readlines(File.join(docker_journal, "calls.log"), chomp: true).each_with_object([]) do |line, calls|
      buffer = buffer ? "#{buffer}\n#{line}" : line
      begin
        calls << Shellwords.split(buffer)
        buffer = nil
      rescue ArgumentError
        next
      end
    end
  end
  
  private

  def volume_folder(name) = File.join(docker_journal, "volumes", name)

  def host_git(*args)
    out, status = Open3.capture2e(Workspace::GIT_ENV, "git", "-C", File.join(remote_dir, "acme/shop.git"), *args)
    status.success? ? out : nil
  end

  def local_git(dir, *args)
    out, status = Open3.capture2e(Workspace::GIT_ENV, "git", "-C", dir, *args)
    status.success? ? out : nil
  end
end
