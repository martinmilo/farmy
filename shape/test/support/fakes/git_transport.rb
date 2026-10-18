# An opt-in mesh-only Git host: validate Docker's actual launch configuration before
# allowing the fake transport to substitute the local bare repository used by real Git.
def play_service_clone(record, mounts)
  source = mounts.find { |mount| mount["target"] == "/workspace" && mount["name"].end_with?("-src") }
  return unless source && record.fetch("process", []).join(" ").match?(/\bgit\b[\s\S]*\bclone\b/)
  name = source["name"].delete_suffix("-src")
  app = containers[name] || { "project" => name, "env" => record["env"], "networks" => record["networks"] }
  operands = record.fetch("process", []).join(" ") + "\n" + record.fetch("env", {}).fetch("REPO", "") + "\n" + app.fetch("env", {}).fetch("REPO", "")
  failure = ($state["clone_results"] || {})[name]
  # Local repositories keep exercising real Git. Ordinary illustrative internet URLs
  # retain the fake host's existing clone/authentication result, without a real network call.
  unless failure
    return if operands.include?("file://")
    return if ($state["git_hosts"] || {}).any? { |url, host| ([url] + Array(host["aliases"])).any? { |address| operands.include?(address) } }
    return unless operands.match?(%r{(?:https?|ssh)://})
  end
  result = failure || clone_result(app)
  ((volumes[source["name"]] ||= {})["files"] ||= {})[".farmy-clone"] = result
  File.write(File.join(volume_dir(source["name"]), ".farmy-clone"), result)
  record["exit"] = result.start_with?("ok") ? 0 : 128
  $stderr.print result.delete_prefix("failed\n") unless record["exit"].zero?
  exit record["exit"]
end

def check_git_container_transport(record, mounts)
  return unless $state["required_git_transport"]
  role = record.dig("labels", "farmy.role")
  return unless %w[git dotfiles].include?(role) || record.fetch("process", []).join(" ").match?(/\bgit\s+(?:clone|fetch|pull|push|ls-remote|archive)\b/)
  env = record.fetch("env", {})
  nets = record.fetch("networks", [])
  config = env.select { |key, _| key.start_with?("GIT_CONFIG_KEY_") }.to_h { |key, value| [value, env["GIT_CONFIG_VALUE_#{key.delete_prefix('GIT_CONFIG_KEY_')}"]] }
  missing = []
  missing << "farmy network" unless nets.include?("farmy") && resolvable_names(nets).include?("farmy-egress")
  %w[HTTP_PROXY HTTPS_PROXY http_proxy https_proxy].each { |key| missing << key unless env[key] == "http://farmy-egress:1055" }
  %w[ALL_PROXY all_proxy].each { |key| missing << key unless env[key] == "socks5h://farmy-egress:1055" }
  missing << "NO_PROXY/no_proxy local bypasses" unless %w[localhost 127.0.0.1 keys farmy-egress].all? { |host| env.fetch("NO_PROXY", "").split(",").include?(host) } && env["NO_PROXY"] == env["no_proxy"]
  ssh = env["GIT_SSH_COMMAND"] || config["core.sshCommand"]
  missing << "SSH ProxyCommand through farmy-egress:1055" unless ssh.to_s.match?(/ProxyCommand=.*nc .*?-X 5 .*?-x farmy-egress:1055 .*?%h .*?%p/)
  missing << "HTTPS-to-SSH insteadOf rule" unless config["url.ssh://git@git.example.com/.insteadOf"] == "https://git.example.com/"
  socket = env["SSH_AUTH_SOCK"].to_s
  agent = mounts.find { |mount| socket.start_with?("#{mount['target']}/") && mount["name"].end_with?("-keys-agent") }
  missing << "mounted route agent socket" unless agent
  broker_ready = agent && containers.any? do |name, broker|
    next false unless broker["service"] == "keys" && broker["state"] == "running" && !(Array(broker["networks"]) & nets).empty?
    next false unless Array(broker["volumes"]).any? { |mount| mount["name"] == agent["name"] }
    $state["execs"].any? do |entry|
      next false unless entry["container"] == name && entry["command"].include?("load") && entry["seq"].to_i > broker["started_seq"].to_i
      (JSON.parse(entry["stdin"].to_s).fetch("secrets", {}) rescue {}).key?("GIT_SSH_KEY")
    end
  end
  missing << "reachable loaded route broker" unless broker_ready
  missing << "private key leaked into Git environment" if env.key?("GIT_SSH_KEY")
  observation = record.merge("phase" => $state["git_transport_phase"], "mounts" => mounts, "broker_ready" => !!broker_ready, "missing" => missing)
  ($state["git_transport_observations"] ||= []) << JSON.parse(JSON.generate(observation))
  return if missing.empty?
  record["exit"] = 128
  fail_with("git container #{record['name'] || role} cannot reach the SSH host through mesh; missing: #{missing.join(', ')}")
end
