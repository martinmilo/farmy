require "timeout"

module EgressControl
  def egress_apps(global: true, shop: nil, allow: [], service_allow: [], definition_allow: [], agents: [], upstream: nil, mesh: false)
    settings
    policy = { "restrict" => global, "allow" => allow, "services" => { "shop" => { "allow" => service_allow } } }
    policy["proxy"] = upstream if upstream
    policy["authkey"] = "TS_AUTHKEY" if mesh
    config = { "egress" => policy, "agents" => agents }
    config["secrets"] = { "unlock" => ["TS_AUTHKEY"] } if mesh
    write_file "farmy.yml", YAML.dump(config)
    define_egress_app "shop", restrict: shop, allow: definition_allow
    define_egress_app "notes"
  end

  def define_egress_app(name, restrict: nil, allow: [])
    data = { "repo" => "none", "image" => "debian:bookworm-slim", "egress" => { "allow" => allow } }
    data["restrict"] = restrict unless restrict.nil?
    write_file "services/#{name}.yml", YAML.dump(data)
  end

  def git_egress_routes
    data = YAML.safe_load(read_file("farmy.yml"))
    data["keys"] = {
      "git" => { "upstream" => "https://code.example.com:8443", "secret" => "GIT_TOKEN", "auth" => "bearer", "git" => true },
      "other" => { "upstream" => "https://other.example.com", "secret" => "OTHER_TOKEN", "auth" => "bearer" }
    }
    write_file "farmy.yml", YAML.dump(data)
  end

  def app_curl(url, service: "shop", direct: false, proxy: nil)
    farmy "run", service, "curl", "--fail", "--silent", "--show-error", *(direct ? ["--noproxy", "*"] : []),
          *(proxy ? ["--proxy", proxy] : []), url
  end

  def assert_internal_only(name)
    c = container(name) or flunk("Expected restricted container #{name} to be running.#{transcript}")
    assert_internal_networks c["networks"], "container #{name}"
  end

  def assert_internal_networks(nets, subject)
    history = Array(docker_state["networks_made"]).to_h { |n| [n["name"], n["internal"]] }
    history.merge!(docker_state["networks"].transform_values { |n| n["internal"] })
    assert !Array(nets).empty? && Array(nets).all? { |n| history[n] == true },
           "Expected #{subject} only on Docker internal networks, never bridge, host or outward farmy; networks: #{Array(nets).map { |n| "#{n}(internal=#{history[n].inspect})" }.join(', ')}.#{transcript}"
  end

  def assert_agents_filtered
    runs = run_containers("agent")
    refute_empty runs, "Expected at least one factory agent invocation.#{transcript}"
    runs.each do |r|
      assert_internal_networks r["networks"], "factory agent #{r['name']}"
      assert_match %r{\Ahttp://}, r.dig("env", "HTTPS_PROXY").to_s, "Expected #{r['name']} to use a filtering HTTP proxy.#{transcript}"
    end
    refute Array(docker_state["networks_made"]).any? { |n| n["name"].match?(/-run-.*-out\z/) }, "Expected no per-run outward -out network.#{transcript}"
  end

  def assert_filtered_request(host, port: 443, status: 200, container: "shop", upstream: nil)
    traffic = Array(docker_state["traffic"]).find { |t| t["host"] == host && t["port"] == port && (container === t["container"]) && t["status"] == status }
    assert traffic, "Expected #{container.inspect} to request #{host}:#{port} and receive #{status}; observed traffic: #{docker_state['traffic'].inspect}.#{transcript}"
    gate = traffic["hops"].first
    known = docker_state["containers"].values + docker_state["runs"]
    gate_record = known.find { |c| (c["name"] == gate || docker_state["containers"][gate].equal?(c)) && c.dig("labels", "farmy.role") == "egress-gate" }
    gate_record ||= docker_state["containers"][gate] if docker_state.dig("containers", gate, "labels", "farmy.role") == "egress-gate"
    assert gate_record, "Expected #{host}:#{port} through a farmy.role=egress-gate proxy; hops: #{traffic['hops'].inspect}.#{transcript}"
    assert_equal upstream, traffic["hops"][1], "Expected #{host}:#{port} forwarded by the gate through #{upstream.inspect}.#{transcript}" if upstream
  end

  def remember_container_starts
    @container_starts = docker_state["containers"].transform_values { |c| c["started_seq"] }
  end

  def assert_direct_request_blocked(host, container:)
    traffic = Array(docker_state["traffic"]).select { |t| t["host"] == host && container === t["container"] }
    assert traffic.any? { |t| t["status"] == 0 && t["hops"].empty? },
           "Expected #{container.inspect} to have no direct route to #{host}, even when it ignores its proxy; got #{traffic.inspect}.#{transcript}"
  end

  def assert_no_container_restarted
    assert_equal @container_starts, docker_state["containers"].transform_values { |c| c["started_seq"] },
                 "Expected policy reload without creating, removing or restarting any container.#{transcript}"
  end

  def assert_saved_allow(host, service: nil, count: 1)
    config = YAML.safe_load(read_file("farmy.yml"))
    entries = service ? config.dig("egress", "services", service, "allow") : config.dig("egress", "allow")
    assert_equal count, Array(entries).count(host), "Expected #{host.inspect} #{count} time(s) in farmy.yml #{service ? "egress.services.#{service}.allow" : 'egress.allow'}, got #{entries.inspect}.#{transcript}"
  end

  def assert_egress_status(service, restricted:, denied:, mode: restricted ? "enforce" : "off")
    assert_equal({ "restricted" => restricted, "denied" => denied, "mode" => mode }, service_json(service)["egress"],
                 "Expected status --json for #{service} to expose restriction and denial count for the TUI.#{transcript}")
  end

  def assert_no_filtering_gate
    gates = docker_state["containers"].select { |_, c| c.dig("labels", "farmy.role") == "egress-gate" }
    assert_empty gates.keys, "Expected no filtering proxy for unrestricted apps.#{transcript}"
  end

  def assert_no_run_filtering_resources
    gates = docker_state["containers"].select { |_, c| c.dig("labels", "farmy.role") == "egress-gate" && c.dig("labels", "farmy.run") }
    assert_empty gates.keys, "Expected run-specific filtering proxies removed after the run.#{transcript}"
    nets = docker_state["networks"].keys.grep(/shop-run-/)
    assert_empty nets, "Expected run networks removed after the run.#{transcript}"
  end

  def assert_catalogue_api_hosts(name, *hosts)
    entry = YAML.safe_load(work_file("agents.yml")).fetch(name)
    assert_equal hosts.sort, Array(entry["api_hosts"]).sort,
                 "Expected #{name}.api_hosts to contain the verified API/auth destinations in FORMATS.md, with citations in catalogue comments."
  end

  def assert_registry_hosts(*hosts)
    data = YAML.safe_load(work_file("egress-hosts.yml"))
    assert_equal hosts.sort, Array(data && data["registries"]).sort,
                 "Expected egress-hosts.yml to ship the named registries set used by app policy."
  end

  # Real proxy process, exercised via its public executable and Unix control socket.
  def start_filter(allow: [], upstream: nil, addresses: ["127.0.0.1"], mode: nil)
    @filter_port = free_port
    @filter_socket = File.join(scratch, "filter.sock")
    @filter_env = { "FARMY_GATE_PORT" => @filter_port.to_s, "FARMY_GATE_SOCKET" => @filter_socket }
    @filter_exe = Target.path("bin/farmy-gate")
    assert File.executable?(@filter_exe), "Expected bin/build to provide executable bin/farmy-gate with serve/load/log/status (FORMATS.md)."
    @filter_pid = Process.spawn(@filter_env, @filter_exe, "serve", out: File.join(scratch, "filter.out"), err: File.join(scratch, "filter.err"))
    deadline = Time.now + 5
    until File.socket?(@filter_socket)
      flunk "Expected farmy-gate serve to open FARMY_GATE_SOCKET. #{filter_output}" if Time.now > deadline
      sleep 0.05
    end
    @filter_addresses = addresses
    @filter_mode = mode
    reload_filter allow: allow, upstream: upstream
  end

  def reload_filter(allow:, upstream: nil)
    payload = { "version" => 1, "upstream" => upstream, "clients" => { "shop" => { "service" => "shop", "addresses" => @filter_addresses, "allow" => allow } } }
    payload["clients"]["shop"]["mode"] = @filter_mode if @filter_mode
    out, status = filter_control "load", stdin: JSON.generate(payload)
    assert status.success?, "Expected farmy-gate load to accept policy #{payload.inspect}; got #{out}. #{filter_output}"
  end

  def reject_filter_reload(text)
    out, status = filter_control "load", stdin: text
    assert_equal 1, status.exitstatus, "Expected invalid filter policy to exit 1; got #{status.exitstatus}: #{out}."
    assert_match(/invalid|version|policy|parse/i, out, "Expected invalid policy refusal to explain the reason; got #{out.inspect}.")
  end

  def filter_control(command, stdin: "")
    Timeout.timeout(5) { Open3.capture2e(@filter_env, @filter_exe, command, stdin_data: stdin) }
  end

  def filter_http(url, headers: {}, method: "GET", body: "")
    uri = URI(url)
    response = nil
    Timeout.timeout(5) do
      socket = TCPSocket.new("127.0.0.1", @filter_port)
      fields = { "Host" => uri.host + (uri.port == 80 ? "" : ":#{uri.port}"), "Connection" => "close" }.merge(headers)
      fields["Content-Length"] = body.bytesize.to_s unless body.empty?
      socket.write "#{method} #{url} HTTP/1.1\r\n#{fields.map { |k, v| "#{k}: #{v}\r\n" }.join}\r\n#{body}"
      response = socket.read
      socket.close
    end
    response
  rescue Timeout::Error => e
    flunk "Expected a proxy HTTP response within 5 seconds for #{url}: #{e}. #{filter_output}"
  end

  def assert_filter_http(url, status:, body: nil, headers: {}, method: "GET", request_body: "")
    response = filter_http(url, headers: headers, method: method, body: request_body)
    assert_match(/\AHTTP\/1\.[01] #{status}\b/, response, "Expected HTTP #{status} for #{url}, got #{response.inspect}. #{filter_output}")
    assert_includes response.split("\r\n\r\n", 2).last.to_s, body if body
  end

  def echo_destination
    server = TCPServer.new("127.0.0.1", 0)
    up = Struct.new(:server, :thread, :url).new(server, nil, "127.0.0.1:#{server.addr[1]}")
    up.thread = Thread.new do
      loop do
        c = server.accept
        bytes = c.readpartial(4096)
        c.write(bytes)
        c.close
      end
    rescue IOError, Errno::EBADF
    end
    (@upstreams ||= []) << up
    up.url
  end

  def assert_filter_tunnel(destination, bytes:)
    Timeout.timeout(5) do
      s = TCPSocket.new("127.0.0.1", @filter_port)
      s.write "CONNECT #{destination} HTTP/1.1\r\nHost: #{destination}\r\n\r\n"
      head = +""
      head << s.read(1) until head.end_with?("\r\n\r\n")
      assert_match(/\AHTTP\/1\.[01] 200\b/, head, "Expected CONNECT 200 for #{destination}. #{filter_output}")
      s.write bytes
      assert_equal bytes, s.read(bytes.bytesize), "Expected an opaque CONNECT tunnel with no TLS inspection."
      s.close
    end
  rescue Timeout::Error
    flunk "Expected CONNECT bytes to be forwarded without waiting for a TLS handshake. #{filter_output}"
  end

  def assert_filter_connect_denied(destination)
    Timeout.timeout(5) do
      s = TCPSocket.new("127.0.0.1", @filter_port)
      s.write "CONNECT #{destination} HTTP/1.1\r\nHost: #{destination}\r\nConnection: close\r\n\r\n"
      response = s.read
      s.close
      assert_match(/\AHTTP\/1\.[01] 403\b/, response, "Expected an unlisted CONNECT destination denied before opening any tunnel; got #{response.inspect}. #{filter_output}")
    end
  end

  def assert_filter_denial(host, port:, container: "shop", service: "shop")
    out, status = filter_control "log"
    assert status.success?, "Expected farmy-gate log to succeed: #{out}."
    rows = out.lines.map { |l| JSON.parse(l) }
    wanted = { "event" => "denied", "host" => host, "port" => port, "container" => container, "service" => service }
    assert rows.any? { |row| wanted.all? { |k, v| row[k] == v } }, "Expected denial #{wanted.inspect}; got #{rows.inspect}."
  end

  def assert_filter_count(service, count)
    out, status = filter_control "status"
    assert status.success?, "Expected farmy-gate status to succeed: #{out}."
    assert_equal count, JSON.parse(out).dig("denied", service), "Expected #{count} denials for #{service}, got #{out}."
  end

  def assert_filter_log_omits(*parts)
    out, status = filter_control "log"
    assert status.success?, "Expected farmy-gate log to succeed: #{out}."
    parts.each do |part|
      refute_includes out + filter_output, part, "Expected denial history and proxy stdout/stderr to omit URL paths, credentials and header values."
    end
  end

  def filter_output
    %w[filter.out filter.err].map { |f| File.exist?(File.join(scratch, f)) ? File.read(File.join(scratch, f)) : "" }.join("\n")
  end

  def after_teardown
    if @filter_pid
      Process.kill("TERM", @filter_pid) rescue nil
      Process.wait(@filter_pid) rescue nil
    end
    super
  end
end
