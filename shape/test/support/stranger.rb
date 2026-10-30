# The stranger: a Linux host with Docker Engine, repositories on GitHub over https with a token route,
# Claude Code with an API key, no mesh, no secrets manager. What the guides must put first for them, and
# what a real Docker shows of their start.
#
#   assert_guide_orders "docs/getting-started.md", "Docker Engine", "Docker Desktop"   each phrase's first mention comes after the one before
#   assert_last_link "docs/getting-started.md", "worked-example.md"                    the guide's last link points there
#   refute_work_file "docs/first-run.md"                                               the work folder ships no such file
#   assert_stderr_once "Cannot autolaunch D-Bus"                                       exactly once on stderr
#   real_shim "start", "shop"           the shim against the real Docker, with only the store a test chose ahead of it on the PATH
#   define_on_http_git_host "shop", "acme/shop"   services/shop.yml: repo: http://githost:3000/acme/shop.git on debian:bookworm-slim,
#                                       and a fragment service githost (container shop-githost) serving that repository, one
#                                       commit "Seed the shop", over plain http on 3000, logging each request's Authorization to /tmp/auth.log
#   assert_owned_by_me                  every file and folder under the containers folder belongs to the user running the tests
#   private_repository "shop"           the service's repository needs credentials: through its git route without the secret, the clone fails
#   docker_context "unix:///run/user/1000/docker.sock"   what docker context inspect names as the current endpoint
#   linux_host                          the test is about a Linux host; it is skipped on another
#   assert_binds "farmy", "/run/user/1000/docker.sock", at: "/var/run/docker.sock"   a bind mount of the container
#   assert_listens_on "shop", 3100, "127.0.0.1"                                       the host address a published port is bound to
module Stranger
  def assert_guide_orders(path, *phrases)
    text = work_file(path)
    missing = phrases.reject { |p| text.include?(p) }
    assert missing.empty?, "Expected the guide #{path} to mention each of #{phrases.map(&:inspect).join(", ")}; it does not mention: #{missing.map(&:inspect).join(", ")}."
    order = phrases.sort_by { |p| text.index(p) }
    assert order == phrases, "Expected the guide #{path} to bring these up in this order, by first mention: #{phrases.map(&:inspect).join(" before ")}; it brings them up as #{order.map(&:inspect).join(", ")}."
  end

  def assert_last_link(path, target)
    links = work_file(path).scan(/\]\(([^)\s]+)\)/).flatten
    assert links.last.to_s.end_with?(target), "Expected the last link of the guide #{path} to point at #{target}; #{links.empty? ? "it has no link" : "its last link points at #{links.last}"}."
  end

  def refute_work_file(name)
    assert !File.exist?(File.join(Target.root, name)), "Expected the work folder to ship no #{name}; it is still there."
  end

  def assert_stderr_once(text)
    n = stderr.scan(text).size
    assert n == 1, "Expected #{text.inspect} exactly once on stderr; it is there #{n} times.#{transcript}"
  end

  # The shim with the real docker; HOME, XDG_* and FARMY_DIR as for every farmy call (support/default_home.rb).
  def real_shim(*args, stdin: "", env: {})
    path = ([store_bin] + ENV.fetch("PATH").split(":").reject { |p| p == Farmy::FAKES }).join(":")
    plumbing = machine_env
    saved = plumbing.keys.to_h { |key| [key, ENV[key]] }
    plumbing.each { |key, val| ENV[key] = val }
    script "farmy", *args, stdin: stdin, env: store_env.merge("PATH" => path).merge(env)
  ensure
    saved&.each { |key, val| ENV[key] = val }
  end

  def define_on_http_git_host(name, repository)
    write_file "services/#{name}.yml", <<~YAML
      repo: http://githost:3000/#{repository}.git
      image: debian:bookworm-slim
      compose:
        githost:
          image: python:3.12-slim
          container_name: #{name}-githost
          command:
            - sh
            - -c
            - |
              set -e
              apt-get update -qq && apt-get install -y -qq git > /dev/null
              git init -q --bare -b main /srv/git/#{repository}.git
              git init -q -b main /tmp/seed && cd /tmp/seed && echo '# seed' > README.md && git add README.md
              git -c user.name=ops -c user.email=ops@example.com commit -q -m 'Seed the shop'
              git push -q /srv/git/#{repository}.git main
              git -C /srv/git/#{repository}.git update-server-info
              exec python3 -c 'import http.server, functools
              class H(http.server.SimpleHTTPRequestHandler):
                  def do_GET(self):
                      open("/tmp/auth.log", "a").write(self.path + " " + str(self.headers.get("Authorization")) + "\\n")
                      super().do_GET()
              http.server.ThreadingHTTPServer(("", 3000), functools.partial(H, directory="/srv/git")).serve_forever()'
          healthcheck:
            test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:3000/#{repository}.git/HEAD')"]
            interval: 2s
            retries: 150
    YAML
    note_situation "services/#{name}.yml clones http://githost:3000/#{repository}.git, served over plain http by its fragment service githost (#{name}-githost), one commit: Seed the shop."
  end

  def assert_owned_by_me(*paths)
    files = paths.empty? ? Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).reject { |f| File.basename(f) == "." } : paths.map { |p| File.join(dir, p) }
    others = files.select { |f| File.lstat(f).uid != Process.uid }.map { |f| "#{f.delete_prefix("#{dir}/")} (uid #{File.lstat(f).uid})" }
    assert others.empty?, "Expected everything farmy wrote in the containers folder to belong to its owner, uid #{Process.uid} (on Docker Engine the control container's root would own it otherwise); these do not: #{others.first(20).join(", ")}.#{transcript}"
  end

  def private_repository(name)
    change_docker_state { |st| (st["private_repos"] ||= []) << name }
    note_situation "The repository of #{name} is private: the host wants a token for it."
  end

  def docker_context(host)
    (@fake_env ||= {})["FAKE_DOCKER_CONTEXT_HOST"] = host
    note_situation "docker context inspect names the endpoint #{host}."
  end

  def linux_host
    skip "this is about a Linux host, and this one is #{RbConfig::CONFIG["host_os"]}" unless RbConfig::CONFIG["host_os"].include?("linux")
  end

  def assert_binds(name, source, at:)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    binds = (c["binds"] || []).map { |b| "#{b["source"]}:#{b["target"]}" }
    assert binds.include?("#{source}:#{at}"), "Expected #{name} to bind-mount #{source} at #{at}; it binds #{binds.empty? ? "nothing" : binds.join(", ")}.\n\n#{docker_situation}#{transcript}"
  end

  def assert_listens_on(name, host_port, address)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    port = c["ports"].find { |p| p["host"].to_s == host_port.to_s } or flunk("Expected #{name} to publish host port #{host_port}; it publishes #{c["ports"].map { |p| p["host"] }.join(", ")}.\n\n#{docker_situation}#{transcript}")
    assert port["ip"] == address, "Expected host port #{host_port} of #{name} to be bound to #{address}; it is bound to #{port["ip"]} (127.0.0.1:#{host_port}:<container port> in the compose file, or every interface when LAN_HOST is set).\n\n#{docker_situation}#{transcript}"
  end
end
