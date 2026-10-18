require "uri"
# The keys broker as a program: bin/farmy-keys of the work folder, started by a test against a fake upstream
# of the test's own. Everything is torn down after the test.
#
#   upstream = fake_upstream                       an HTTP server recording what it receives; answers 200 "ok"
#   fake_upstream status: 302, headers: { "Location" => "{origin}/moved" }   ({origin}: the upstream's own URL)
#   start_broker routes: { "git" => "#{upstream.url} basic x-access-token GIT_TOKEN" }
#   load_broker "GIT_TOKEN" => "frg_…"           what farmy would load: bin/farmy-keys load, JSON on stdin
#   through_broker "/git/acme/shop.git/info/refs", headers: { … }   → a Net::HTTPResponse
#   agent_identities                               ssh-add -l against the broker's SSH agent socket
#   upstream.requests                              [{ "path" => …, "headers" => { lower-cased name => value } }]
#   proxy = fake_proxy · start_broker routes: …, env: { "HTTP_PROXY" => proxy.url }   an HTTP proxy; proxy.targets
require "socket"
require "net/http"
require "json"
require "open3"
require "tmpdir"

module Broker
  FakeUpstream = Struct.new(:server, :thread, :requests, :url)

  def fake_upstream(status: 200, headers: {}, body: "ok")
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    up = FakeUpstream.new(server, nil, [], "http://127.0.0.1:#{port}")
    up.thread = Thread.new do
      loop do
        client = server.accept
        Thread.new(client) { |c| serve_once(c, up, status, headers, body) }
      end
    rescue IOError, Errno::EBADF
      nil
    end
    (@upstreams ||= []) << up
    note_situation "A fake upstream listens at #{up.url} and answers #{status}."
    up
  end

  def start_broker(routes:, env: {})
    given = env
    @broker_port = free_port
    @broker_socket = File.join(scratch, "keys.sock")
    @agent_socket = File.join(scratch, "agent.sock")
    env = { "FARMY_ROUTES" => routes.keys.join(" "), "FARMY_PORT" => @broker_port.to_s, "FARMY_SOCKET" => @broker_socket, "FARMY_AGENT_SOCKET" => @agent_socket }
    routes.each { |name, spec| env["FARMY_ROUTE_#{name.upcase.tr("-", "_")}"] = spec }
    env = env.merge(given)
    exe = Target.path("bin/farmy-keys")
    raise Minitest::Assertion, "The tests run bin/farmy-keys in the work folder, and nothing executable is there." unless File.executable?(exe)
    command = env.delete("FARMY_TEST_PARENT") ? ["sh", "-c", "\"$0\" serve & wait", exe] : [exe, "serve"]
    @broker = Process.spawn(env, *command, out: File.join(scratch, "broker.out"), err: File.join(scratch, "broker.err"))
    deadline = Time.now + 10
    until broker_up?
      raise Minitest::Assertion, "bin/farmy-keys serve did not answer /-/health within 10 s.\n\n#{broker_output}" if Time.now > deadline
      sleep 0.1
    end
    note_situation "The broker runs with the routes: #{routes.map { |n, s| "#{n} → #{s}" }.join("; ")}."
  end

  # An HTTP proxy: takes an absolute-form request (GET http://host:port/path) or a CONNECT and passes it
  # on, recording the target. proxy.url for HTTP_PROXY / HTTPS_PROXY; proxy.targets what went through.
  # status: answers directly after recording the target, without any upstream or DNS dependency.
  def fake_proxy(status: nil)
    server = TCPServer.new("127.0.0.1", 0)
    px = Struct.new(:server, :url, :targets, :thread, :status).new(server, "http://127.0.0.1:#{server.addr[1]}", [], nil, status)
    px.thread = Thread.new do
      loop do
        client = server.accept
        Thread.new(client) { |c| proxy_once(c, px) }
      end
    rescue IOError, Errno::EBADF
    end
    (@upstreams ||= []) << px
    note_situation "A fake HTTP proxy listens at #{px.url}#{status ? " and answers #{status} without contacting an upstream" : ""}."
    px
  end

  # The loading socket the broker was given exists and is a socket.
  def assert_broker_socket
    assert File.socket?(@broker_socket), "Expected the broker to listen on the socket it was given, #{@broker_socket}; there is #{File.exist?(@broker_socket) ? "something else" : "nothing"} there.\n\n#{broker_output}"
  end

  def load_broker(secrets)
    out, status = Open3.capture2e({ "FARMY_SOCKET" => @broker_socket }, Target.path("bin/farmy-keys"), "load",
                                  stdin_data: JSON.generate("version" => 1, "secrets" => secrets))
    raise Minitest::Assertion, "bin/farmy-keys load failed:\n#{out}" unless status.success?
    note_situation "The broker was loaded with: #{secrets.keys.join(", ")}."
  end

  def through_broker(path, headers: {}, method: :get)
    uri = URI("http://127.0.0.1:#{@broker_port}#{path}")
    req = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
    headers.each { |k, v| req[k] = v }
    Net::HTTP.start(uri.host, uri.port, read_timeout: 10) { |http| http.request(req) }
  end

  # What the broker's SSH agent holds, as `ssh-add -l` lists it (fingerprints and comments).
  # farmy-keys load with this exact text on stdin (a payload farmy sent), raising when it fails.
  def load_broker_raw(text)
    out, status = Open3.capture2e({ "FARMY_SOCKET" => @broker_socket }, Target.path("bin/farmy-keys"), "load", stdin_data: text)
    raise Minitest::Assertion, "bin/farmy-keys load failed:\n#{out}\n\n#{broker_output}" unless status.success?
    note_situation "The broker was loaded with what farmy sent."
  end

  # farmy-keys load, returning [its output, its exit code] instead of raising.
  def load_broker_answer(secrets)
    out, status = Open3.capture2e({ "FARMY_SOCKET" => @broker_socket }, Target.path("bin/farmy-keys"), "load", stdin_data: JSON.generate("version" => 1, "secrets" => secrets))
    [out, status.exitstatus]
  end

  # farmy-keys loaded: the names of the secrets the broker holds, one per line.
  def broker_loaded
    out, status = Open3.capture2e({ "FARMY_SOCKET" => @broker_socket }, Target.path("bin/farmy-keys"), "loaded")
    raise Minitest::Assertion, "bin/farmy-keys loaded failed (exit #{status.exitstatus}):\n#{out}\n\n#{broker_output}" unless status.success?
    out.lines(chomp: true)
  end

  def agent_identities
    out, = Open3.capture2e({ "SSH_AUTH_SOCK" => @agent_socket }, "ssh-add", "-l")
    out
  end

  # The broker started by a parent of its own (sh), so that the parent can be made to go away.
  def start_broker_under_parent(routes:)
    start_broker routes: routes, env: { "FARMY_TEST_PARENT" => "1" }
  end

  # Stops the broker with a signal and waits for it to exit.
  def stop_broker(signal)
    @stopped_how = "stopped with #{signal}"
    Process.kill(signal, @broker)
    exited = wait_until(10) { Process.wait(@broker, Process::WNOHANG) }
    raise Minitest::Assertion, "bin/farmy-keys serve did not exit within 10 s of #{signal}.\n\n#{broker_output}" unless exited
    @broker = nil
  end

  # Kills the broker's parent with SIGKILL, leaving the broker to notice by itself.
  def end_broker_parent
    @stopped_how = "left without its parent (killed with KILL)"
    Process.kill("KILL", @broker)
    Process.wait(@broker)
    @broker = nil
  end

  # Nothing the broker started, its SSH agent included, outlives it; nor the broker itself.
  def assert_broker_left_nothing_running
    left = nil
    wait_until(5) { (left = Processes.descendants.reject { |_, state| state == "Z" }.map(&:last)).empty? }
    assert_empty left, "Expected the broker and the SSH agent it runs to end when the broker is #{@stopped_how}; " \
                       "5 s later these were still running:\n#{left.map { |l| "  #{l}" }.join("\n")}\n\n#{broker_output}"
  end

  def wait_until(seconds)
    deadline = Time.now + seconds
    until (answer = yield)
      return nil if Time.now > deadline
      sleep 0.05
    end
    answer
  end

  def broker_output = ["  broker stdout:", File.read(File.join(scratch, "broker.out")).gsub(/^/, "    "), "  broker stderr:", File.read(File.join(scratch, "broker.err")).gsub(/^/, "    ")].join("\n")

  def after_teardown
    super
    if @broker
      Process.kill("TERM", @broker) rescue nil
      Process.wait(@broker) rescue nil
    end
    (@upstreams || []).each { |up| up.server.close rescue nil; up.thread.kill }
  end

  private

  def broker_up?
    Net::HTTP.get_response(URI("http://127.0.0.1:#{@broker_port}/-/health")).code == "200"
  rescue StandardError
    false
  end

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    s.addr[1].tap { s.close }
  end

  def proxy_once(client, px)
    line = client.gets or return
    method, target, version = line.split(" ")
    headers = []
    while (h = client.gets) && h != "\r\n"
      headers << h
    end
    uri = URI.parse(target) unless method == "CONNECT"
    px.targets << (uri ? "#{uri.scheme}://#{uri.host}:#{uri.port}#{uri.path}" : "https://#{target}")
    if px.status
      client.write "HTTP/1.1 #{px.status} Fake proxy response\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      return
    end
    if method == "CONNECT"
      host, port = target.split(":")
      upstream = TCPSocket.new(host, port.to_i)
      client.write "HTTP/1.1 200 Connection Established\r\n\r\n"
      a = Thread.new { IO.copy_stream(client, upstream) rescue nil; upstream.close_write rescue nil }
      IO.copy_stream(upstream, client) rescue nil
      a.kill   # the upstream is done: the tunnel ends, whatever the client still holds open
      upstream.close rescue nil
    else
      upstream = TCPSocket.new(uri.host, uri.port)
      upstream.write "#{method} #{uri.request_uri} #{version}\r\n"
      headers.each { |h| upstream.write h unless h =~ /\Aproxy-/i }
      upstream.write "\r\n"
      length = headers.find { |h| h =~ /\Acontent-length:/i }&.split(":", 2)&.last.to_i
      upstream.write client.read(length) if length > 0
      IO.copy_stream(upstream, client) rescue nil
      upstream.close rescue nil
    end
  ensure
    client.close rescue nil
  end

  def serve_once(client, up, status, headers, body)
    line = client.gets or return
    method, path, = line.split(" ")
    received = {}
    while (h = client.gets) && h != "\r\n"
      name, val = h.split(":", 2)
      received[name.strip.downcase] = val.to_s.strip
    end
    request_body = received["content-length"] ? client.read(received["content-length"].to_i) : ""
    up.requests << { "method" => method, "path" => path, "headers" => received, "body" => request_body }
    client.write "HTTP/1.1 #{status} #{status == 200 ? "OK" : "Moved"}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n"
    headers.each { |k, v| client.write "#{k}: #{v.gsub("{origin}", up.url)}\r\n" }
    client.write "\r\n#{body}"
  ensure
    client.close rescue nil
  end
end
