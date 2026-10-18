# The Docker fake's network model. No policy is inferred from a farmy mode: requests use the
# networks, proxy environment and client policy actually installed by the program.
require "uri"

def fake_ip(name)
  bytes = Digest::SHA256.digest(name).bytes
  "172.28.#{bytes[0]}.#{2 + bytes[1] % 250}"
end

def filtering_gate?(c) = c.dig("labels", "farmy.role") == "egress-gate"

def gate_command(command, stdin, c)
  return unless command.first.to_s.end_with?("farmy-gate")
  case command[1]
  when "load"
    policy = JSON.parse(stdin.to_s)
    fail_with("farmy-gate: invalid policy version") unless policy["version"] == 1 && policy["clients"].is_a?(Hash)
    c["gate_policy"] = policy
  when "log"
    Array(c["events"] || c["denials"]).last(100).each { |d| puts JSON.generate(d) }
  when "status"
    puts JSON.generate("version" => 1, "denied" => Array(c["denials"]).group_by { |d| d["service"] }.transform_values(&:size))
  else
    unhandled("farmy-gate #{command[1]}")
  end
  exit 0
end

def peer_on_network(host, nets)
  containers.find do |name, c|
    shared = Array(c["networks"]) & Array(nets)
    next false if shared.empty?
    aliases = Array($state["network_joins"]).select { |j| j["action"] == "connect" && shared.include?(j["network"]) && j["container"] == name }.flat_map { |j| j["aliases"] }
    ([name, c["service"], fake_ip(name)] + Array(c["aliases"]) + aliases).include?(host)
  end
end

def host_allowed?(entries, host, port)
  host = host.downcase.delete_suffix(".")
  Array(entries).any? do |entry|
    match = /\A(\[[^\]]+\]|[^:]+)(?::(\d+))?\z/.match(entry.to_s)
    next false unless match
    pattern = match[1].delete_prefix("[").delete_suffix("]").downcase.delete_suffix(".")
    port_matches = !match[2] || match[2].to_i == port
    port_matches && (pattern.start_with?("*.") ? host.end_with?(pattern.delete_prefix("*")) && host != pattern.delete_prefix("*.") : host == pattern)
  end
end

def network_request(c, name, url, direct: false, proxy: nil)
  uri = URI(url)
  host, port = uri.host, uri.port
  nets = Array(c["networks"])
  env = c["env"] || {}
  proxy ||= env[uri.scheme == "https" ? "HTTPS_PROXY" : "HTTP_PROXY"] || env[uri.scheme == "https" ? "https_proxy" : "http_proxy"]
  event = { "container" => name, "host" => host, "port" => port, "url" => url, "hops" => [] }
  code, body = 200, "ok"
  if !direct && proxy && !proxy.empty?
    proxy_uri = URI(proxy)
    peer = peer_on_network(proxy_uri.host, nets)
    if peer && filtering_gate?(peer.last)
      gate_name, gate = peer
      event["hops"] << gate_name
      policy = gate["gate_policy"] || {}
      client = (policy["clients"] || {}).find do |client_name, rules|
        rules.key?("addresses") ? Array(rules["addresses"]).include?(fake_ip(name)) : client_name == name
      end
      audit = client && client.last["mode"] == "audit"
      if !client || (!audit && !host_allowed?(client.last["allow"], host, port))
        identity, rules = client || ["unknown", { "service" => "unknown" }]
        denial = { "event" => "denied", "timestamp" => "2026-10-15T12:00:00Z", "host" => host, "port" => port, "container" => identity, "service" => rules["service"] }
        (gate["denials"] ||= []) << denial
        (gate["events"] ||= []) << denial
        log = ($state["logs"][gate_name] ||= { "text" => "", "stream" => "stdout", "after" => 0, "reads" => 0 })
        log["text"] << JSON.generate(denial) + "\n"
        code, body = 403, "denied #{host}:#{port} container=#{identity}"
      elsif policy["upstream"]
        upstream = URI(policy["upstream"])
        up_peer = peer_on_network(upstream.host, gate["networks"])
        event["hops"] << (up_peer ? up_peer.first : upstream.host)
        unless (up_peer && reaches_out?(up_peer.last["networks"], {})) || (!up_peer && outbound?(gate["networks"]))
          code, body = 502, "upstream unreachable #{upstream.host}"
        end
      elsif !outbound?(gate["networks"])
        code, body = 502, "gate has no route out"
      end
      if audit
        key = [client.first, host.downcase.delete_suffix("."), port]
        unless (gate["observed"] ||= []).include?(key)
          gate["observed"] << key
          observation = { "event" => "allowed", "mode" => "audit", "timestamp" => "2026-10-15T12:00:00Z", "host" => key[1], "port" => port, "container" => client.first, "service" => client.last["service"] }
          (gate["events"] ||= []) << observation
          log = ($state["logs"][gate_name] ||= { "text" => "", "stream" => "stdout", "after" => 0, "reads" => 0 })
          log["text"] << JSON.generate(observation) + "\n"
        end
      end
    elsif (peer && outbound?(peer.last["networks"])) || (!peer && outbound?(nets))
      event["hops"] << (peer ? peer.first : proxy_uri.host)
    else
      code, body = 0, "no route to proxy #{proxy_uri.host}"
    end
  elsif !peer_on_network(host, nets) && !outbound?(nets)
    code, body = 0, "no route out to #{host}:#{port}"
  end
  event["status"] = code
  ($state["traffic"] ||= []) << event
  [code, body]
end

def curl_play(words, c)
  return unless c && File.basename(words.first.to_s) == "curl"
  url = words.reverse.find { |w| w.start_with?("http://", "https://") } or return
  proxy_index = words.index("--proxy") || words.index("-x")
  direct = words.include?("--noproxy") && words[words.index("--noproxy") + 1] == "*"
  code, body = network_request(c, container_name_of(c), url, direct: direct, proxy: proxy_index && words[proxy_index + 1])
  if code.zero? || code >= 400
    $stderr.puts "curl: #{body} (#{code.zero? ? 'network unreachable' : "HTTP #{code}"})"
    exit(code.zero? ? 7 : 22)
  end
  puts body
  exit 0
end
