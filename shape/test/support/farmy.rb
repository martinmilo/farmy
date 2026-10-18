# farmy's own vocabulary. The test's folder plays the "containers" folder on the host:
# services/<name>.yml, services/<name>.env and .env live in it, and farmy runs there.
#
#   farmy "start", "shop"                                   run farmy (stdin:, env: as cli)
#   settings lan_host: "workshop.local"                   write .env (the Git identity by default)
#   host_git_identity "Ines Hartmann", "ines@hartmann.dev" what the host's Git is configured with
#   docker_is_down                                         Docker does not answer
#   remote_repository "acme/toolkit", "Dockerfile" => "...", on: "main"   files committed on the test's own
#                                                          git host: a folder of bare repositories
#   remote_url "acme/toolkit"                              its file:// clone URL, for repo:
#   define_from_remote "toolkit", "acme/toolkit"           services/toolkit.yml from the fixture, repo: on that host
#   shim "init"                                            the shim in the work folder, the fake docker on the PATH
#   docker "build", "-t", "x", "-", stdin: "FROM …"       ask the fake docker something directly
#   assert_builds "farmy:local", 1                         how often that tag was built
#   assert_publishes_nothing "toolkit"                     no host port at all
#   assert_binds_within_workspace                          no bind mount from outside the containers folder
#   status_json · service_json "shop"                       farmy status --json, parsed
#   root_file "README.md" · assert_commands_documented_in  the repository's front page, held to farmy help
#   listening "shop", 3000 · volume_file "shop-agents", "claude/agent.status", "…" · process_in "shop", "claude"
#                                                          what the fake answers from inside a container
#
# Docker is the fake in support/fakes/bin, put first on the PATH. It records every call and keeps
# the containers, images, volumes and networks it was asked for, in a folder of its own per test;
# the assertions read that folder.
#
#   assert_running "shop", "shop-pg"   · assert_stopped "shop"   · refute_container "shop"
#   assert_publishes "shop", "3100:3000"                       host port 3100 reaches the container's 3000
#   assert_init "shop", "shop-pg"                               runs with an init process
#   assert_env "shop", "REPO", "https://..."                   · refute_env "shop", "GIT_TOKEN"
#   assert_mounted "shop", "shop-src"                           a named volume is mounted in it
#   assert_volume "shop-src"                                   · refute_volume "shop-src"
#   assert_ran_in "shop-pg", /CREATE DATABASE/                 a command was run in it with docker exec
#   assert_built target: "base", files: [...], dockerfile_includes: "...", with_arg: "TOOLS=jq", file_content: ["pins.tsv", text]
#   assert_image "shop-pg", "postgres:16"   · assert_mounted "shop-pg", "shop-pg-data", at: "/var/lib/postgresql"
#   assert_ran_in "shop", "bin/setup", in: "/workspace/app"   · assert_ran_in_order "shop", "bin/setup", "bin/rails db:prepare"
#   assert_started_before "shop", "notes"
#   secrets_provider GIT_TOKEN: "frg_…"   · secrets_provider_failing   · provider_log
#   assert_loaded_into "shop-keys", "GIT_TOKEN"   · refute_loaded_into   · refute_secret_anywhere "frg_…"
#   value_loaded_into "shop-keys", "GIT_SSH_KEY" · stdin_loaded_into · assert_loaded_since_start · secrets_provider_raw
require "json"
require "tmpdir"
require "fileutils"
require "shellwords"
require "open3"
require "digest"

module Farmy
  FAKES = File.join(TEST_ROOT, "support", "fakes", "bin")

  # The plumbing (the fake docker on the PATH, its journal, Docker being down) goes through the
  # process environment, so that the transcript shows the command as a user would type it.
  def farmy(*args, stdin: "", env: {})
    plumbing = farmy_env
    saved = plumbing.keys.to_h { |key| [key, ENV[key]] }
    plumbing.each { |key, val| ENV[key] = val }
    env = { "GIT_CONFIG_GLOBAL" => @host_gitconfig }.merge(env) if @host_gitconfig
    cli(*args, stdin: stdin, env: env)
  ensure
    saved&.each { |key, val| ENV[key] = val }
  end

  # The shim in the work folder with the fake docker on the PATH: the seam between it and the control image.
  def shim(*args, stdin: "", env: {})
    plumbing = farmy_env
    saved = plumbing.keys.to_h { |key| [key, ENV[key]] }
    plumbing.each { |key, val| ENV[key] = val }
    script "farmy", *args, stdin: stdin, env: env
  ensure
    saved&.each { |key, val| ENV[key] = val }
  end

  # farmy status --json, parsed; service_json "shop" is one service's entry.
  def status_json
    JSON.parse(stdout)
  rescue JSON::ParserError
    flunk "Expected stdout to be the JSON of farmy status --json.#{transcript}"
  end

  def service_json(name)
    status_json["services"].find { |s| s["name"] == name } or flunk("Expected a service named #{name} in the JSON; it has: #{status_json["services"].map { |s| s["name"] }.join(", ")}.#{transcript}")
  end

  # What the fake docker answers from inside a container, set by the test: something listens on these
  # container ports; a file with this content on a volume; a process running in the container.
  def listening(name, *ports)
    change_docker_state { |s| (s["containers"][name] or flunk("Expected a container named #{name} to exist before the test sets what listens in it; it does not (did the start fail?).#{transcript}"))["listening"] = ports }
    note_situation "In #{name}, something listens on #{ports.join(", ")}."
  end

  def volume_file(volume, path, content)
    change_docker_state { |s| ((s["volumes"][volume] ||= {})["files"] ||= {})[path] = content }
    note_situation "The volume #{volume} holds #{path}: #{content.strip.inspect}."
  end

  def process_in(name, *commands)
    change_docker_state { |s| ((s["containers"][name] or flunk("Expected a container named #{name} to exist before the test sets what runs in it; it does not (did the start fail?).#{transcript}"))["processes"] ||= []).concat(commands) }
    note_situation "In #{name} runs: #{commands.join(", ")}."
  end

  # A file at the repository root (above the work folder): the README, CONTRIBUTING.md.
  def root_file(name)
    File.read(File.join(Target.root, "..", name))
  rescue Errno::ENOENT
    flunk "Expected #{name} at the repository root, next to the work folder, and there is none."
  end

  # The last command was farmy help. Every command its COMMANDS section lists appears in the text as
  # `farmy <command>` inside a code span or a code block, and every `farmy <word>` in code there is a
  # command the usage lists (`farmy` alone, and farmy followed by a placeholder, count as nothing).
  def assert_commands_documented_in(text)
    listed = stdout.lines.drop_while { |l| !l.start_with?("COMMANDS") }.drop(1).take_while { |l| !l.strip.empty? }
    commands = listed.filter_map { |l| l[/\A  (\S+)/, 1] }.uniq
    assert !commands.empty?, "Expected farmy help to list commands under COMMANDS.#{transcript}"
    code = text.scan(/```.*?```/m).join("\n") + "\n" + text.scan(/`[^`\n]+`/).join("\n")
    named = code.scan(/(?:\A|[^\w\/.-])farmy\s+(-{0,2}[a-z][a-z-]*)\b/).flatten.uniq
    missing = commands - named
    extra = named - commands
    assert missing.empty?, "Expected the repository-root README.md (one directory above work/) to name every command farmy help lists, as `farmy <command>` in a code span or block; it does not name: #{missing.join(", ")}.#{transcript}"
    assert extra.empty?, "Expected every `farmy <word>` in the repository-root README.md (one directory above work/) to be a command farmy help lists; these are not: #{extra.join(", ")}.#{transcript}"
  end

  # The fake docker, asked directly (a test that prepares what Docker holds before the program runs).
  def docker(*args, stdin: "")
    out, status = Open3.capture2e(farmy_env, "docker", *args, stdin_data: stdin, chdir: dir)
    raise "docker #{args.join(" ")} failed in the test's setup:\n#{out}" unless status.success?
    out
  end

  # That image tag was built this many times (docker build -t <tag>), by anyone.
  def assert_builds(tag, count)
    calls = File.join(docker_journal, "calls.log")
    lines = File.exist?(calls) ? File.readlines(calls).select { |l| l.start_with?("build ") && l.include?(" -t #{tag} ") } : []
    assert lines.size == count, "Expected the image #{tag} to have been built #{count} time#{"s" unless count == 1}; it was built #{lines.size} time#{"s" unless lines.size == 1}.\n\n#{docker_situation}#{transcript}"
  end

  def settings(name: "Ines Hartmann", email: "ines@hartmann.dev", lan_host: nil, **more)
    pairs = { "GIT_USER_NAME" => name, "GIT_USER_EMAIL" => email, "LAN_HOST" => lan_host }.merge(more.transform_keys(&:to_s))
    write_file ".env", pairs.compact.map { |key, val| "#{key}=#{val}\n" }.join
    note_situation ".env holds: #{pairs.map { |key, val| "#{key}=#{val.nil? ? "(not set)" : val}" }.join("  ")}"
  end

  def host_git_identity(name, email)
    @host_gitconfig = File.join(scratch, "gitconfig")
    File.write(@host_gitconfig, "[user]\n\tname = #{name}\n\temail = #{email}\n")
    note_situation "The host's Git is configured as #{name} <#{email}>."
  end

  def docker_is_down
    @docker_down = true
    note_situation "Docker is not running."
  end

  # The clone URL of a repository on the test's own git host (a folder of bare repositories).
  def remote_url(path)
    "file://#{remote_dir}/#{path}.git"
  end

  # services/<name>.yml from test/fixtures/definitions/<name>.yml, with repo: on the test's git host.
  def define_from_remote(name, path, branch: nil)
    write_file "services/#{name}.yml", "repo: #{remote_url(path)}\n#{branch ? "branch: #{branch}\n" : ""}#{fixture("definitions/#{name}.yml")}"
  end

  # Commits the files on that branch of the repository, creating both when they are new.
  def remote_repository(path, on: "main", **files)
    repo = File.join(remote_dir, "#{path}.git")
    unless File.directory?(repo)
      FileUtils.mkdir_p(repo)
      remote_git("init", "--quiet", "--bare", "--initial-branch=main", repo)
    end
    Dir.mktmpdir("checkout-") do |checkout|
      remote_git("clone", "--quiet", repo, checkout)
      remote_git("-C", checkout, "checkout", "--quiet", "-B", on)
      files.each do |name, content|
        FileUtils.mkdir_p(File.dirname(File.join(checkout, name)))
        File.write(File.join(checkout, name), content)
      end
      remote_git("-C", checkout, "add", "--all")
      remote_git("-C", checkout, "commit", "--quiet", "--message", "Update #{files.keys.join(", ")}")
      remote_git("-C", checkout, "push", "--quiet", "origin", on)
    end
    note_situation "On the git host, #{path} (#{on}) holds: #{files.keys.join(", ")}."
  end

  # ── secrets ──
  # A fake provider in the test's folder, bin/provider, speaking the protocol of FORMATS.md: it answers the
  # given secrets, lists the rest as missing, and writes what it was asked and its environment to provider.log.
  def secrets_provider(**secrets)
    write_executable "bin/provider", <<~RB
      #!/usr/bin/env ruby
      require "json"
      request = JSON.parse($stdin.read)
      state = (JSON.parse(File.read(File.join(ENV["FAKE_DOCKER_JOURNAL"], "state.json"))) rescue {})
      running = (state["containers"] || {}).select { |_, c| c["state"] == "running" }.keys.sort
      File.write("provider.log", "asked: \#{request["secrets"].join(" ")}\nenv: \#{ENV.select { |k, _| k.start_with?("INFISICAL_") || k.end_with?("_PROXY") }.map { |k, v| "\#{k}=\#{v}" }.join(" ")}\nrunning: \#{running.join(" ")}\n")
      have = JSON.parse(%q(#{secrets.transform_keys(&:to_s).to_json}))
      puts JSON.generate("version" => 1, "secrets" => have.select { |k, _| request["secrets"].include?(k) },
                         "missing" => request["secrets"] - have.keys)
    RB
    note_situation "The provider bin/provider has: #{secrets.keys.join(", ")}#{" (none)" if secrets.empty?}."
  end

  # A provider that answers with the protocol's error form (exit 0).
  def secrets_provider_erring(message = "not logged in")
    write_executable "bin/provider", "#!/bin/sh\nprintf '{\"version\":1,\"error\":\"%s\"}\n' '#{message}'\n"
    note_situation "The provider bin/provider answers {\"error\": \"#{message}\"}."
  end

  def secrets_provider_failing(message = "not logged in")
    write_executable "bin/provider", "#!/bin/sh\necho 'provider: #{message}' >&2\nexit 3\n"
    note_situation "The provider bin/provider fails with: #{message}."
  end

  def provider_log = read_file("provider.log")

  # A provider that answers, and says on stderr what it saw: the unlocking value and a secret's value
  # among other words, as a careless provider would.
  def secrets_provider_chatty(stderr:, **secrets)
    write_executable "bin/provider", <<~RB
      #!/usr/bin/env ruby
      require "json"
      request = JSON.parse($stdin.read)
      $stderr.puts %q(#{stderr})
      have = JSON.parse(%q(#{secrets.transform_keys(&:to_s).to_json}))
      puts JSON.generate("version" => 1, "secrets" => have.select { |k, _| request["secrets"].include?(k) }, "missing" => request["secrets"] - have.keys)
    RB
    note_situation "The provider bin/provider has: #{secrets.keys.join(", ")}, and says on stderr: #{stderr}"
  end

  # The broker was loaded with these secrets: an `exec -i … farmy-keys load` received them on stdin.
  def assert_loaded_into(name, *secrets)
    loads = docker_state["execs"].select { |e| e["container"] == name && e["command"].include?("load") && e["stdin"] }
    assert !loads.empty?, "Expected #{name} to have been loaded (docker exec -i #{name} farmy-keys load, the secrets on stdin), and it was not.\n\n#{docker_situation}#{transcript}"
    given = loads.flat_map { |e| (JSON.parse(e["stdin"])["secrets"] || {}).keys rescue [] }
    secrets.each { |s| assert given.include?(s), "Expected #{s} among the secrets loaded into #{name}; loaded: #{given.empty? ? "none" : given.join(", ")}.\n\n#{docker_situation}#{transcript}" }
  end

  def refute_loaded_into(name, secret)
    loads = docker_state["execs"].select { |e| e["container"] == name && e["command"].include?("load") && e["stdin"] }
    given = loads.flat_map { |e| (JSON.parse(e["stdin"])["secrets"] || {}).keys rescue [] }
    refute given.include?(secret), "Expected #{secret} not to be loaded into #{name}, and it was.\n\n#{docker_situation}#{transcript}"
  end

  # The value is in no docker command line, no container's environment, no file under .work, and not in
  # the last command's output.
  # The JSON of the last load into a container (docker exec -i <name> farmy-keys load), as farmy sent it.
  def stdin_loaded_into(name)
    e = docker_state["execs"].reverse.find { |x| x["container"] == name && x["command"].include?("load") && x["stdin"] }
    e ? e["stdin"] : flunk("Expected #{name} to have been loaded (docker exec -i #{name} farmy-keys load); it was not.\n\n#{docker_situation}#{transcript}")
  end

  # The value of one secret in the last load into a container, byte for byte.
  def value_loaded_into(name, secret)
    payload = JSON.parse(stdin_loaded_into(name)) rescue flunk("Expected the load into #{name} to be JSON; it is not: #{stdin_loaded_into(name)[0, 80].inspect}.#{transcript}")
    payload.dig("secrets", secret) or flunk("Expected the load into #{name} to hold #{secret}; it holds #{(payload["secrets"] || {}).keys.join(", ")}.#{transcript}")
  end

  # The container was loaded with these secrets since it last started (a load before that is gone with the old process).
  def assert_loaded_since_start(name, *secrets)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    loads = docker_state["execs"].select { |e| e["container"] == name && e["command"].include?("load") && e["stdin"] && e["seq"].to_i > c["started_seq"].to_i }
    given = loads.flat_map { |e| (JSON.parse(e["stdin"])["secrets"] || {}).keys rescue [] }
    missing = secrets - given
    assert missing.empty?, "Expected #{name} to have been loaded with #{secrets.join(", ")} since it last started; #{loads.empty? ? "nothing was loaded into it since then" : "missing: #{missing.join(", ")}"}.\n\n#{docker_situation}#{transcript}"
  end

  # A provider that answers these values as given, multi-line ones included (a Ruby provider, JSON-correct).
  def secrets_provider_raw(**secrets)
    write_executable "bin/provider", <<~RB
      #!/usr/bin/env ruby
      require "json"
      request = JSON.parse($stdin.read)
      have = JSON.parse(#{JSON.generate(JSON.generate(secrets.transform_keys(&:to_s)))})
      puts JSON.generate("version" => 1, "secrets" => have.select { |k, _| request["secrets"].include?(k) }, "missing" => request["secrets"] - have.keys)
    RB
    note_situation "The provider bin/provider has: #{secrets.keys.join(", ")}."
  end

  def refute_secret_anywhere(value)
    places = []
    calls = File.join(docker_journal, "calls.log")
    places << "a docker command line" if File.exist?(calls) && File.read(calls).include?(value)
    docker_state["containers"].each { |n, c| places << "the environment of #{n}" if c["env"].values.any? { |v| v.to_s.include?(value) } }
    docker_state["containers"].each { |n, c| places << "a label of #{n}" if c["labels"].values.any? { |v| v.to_s.include?(value) } }
    Dir.glob(File.join(dir, ".work", "**", "*"), File::FNM_DOTMATCH).each do |f|
      places << "the file #{f.delete_prefix("#{dir}/")}" if File.file?(f) && File.read(f).include?(value)
    end
    places << "stdout" if stdout.include?(value)
    places << "stderr" if stderr.include?(value)
    assert places.empty?, "Expected the secret #{value.inspect} nowhere; it is in #{places.join(", ")}.\n\n#{docker_situation}#{transcript}"
  end

  # ── what Docker was asked for ──

  def assert_running(*names)
    names.each do |name|
      c = container(name)
      assert c && c["state"] == "running", "Expected a running container named #{name}.\n\n#{docker_situation}#{transcript}"
    end
  end

  def assert_stopped(*names)
    names.each do |name|
      c = container(name)
      assert c, "Expected a stopped container named #{name}, but Docker has no container of that name.\n\n#{docker_situation}#{transcript}"
      assert c["state"] != "running", "Expected the container #{name} to be stopped, but it is running.\n\n#{docker_situation}#{transcript}"
    end
  end

  def refute_container(*names)
    names.each do |name|
      refute container(name), "Expected Docker to have no container named #{name}.\n\n#{docker_situation}#{transcript}"
    end
  end

  def assert_publishes(name, *mappings)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    actual = c["ports"].map { |p| "#{p["host"]}:#{p["container"]}" }
    mappings.each do |mapping|
      assert actual.include?(mapping), "Expected #{name} to publish host port #{mapping.sub(":", " to container port ")}; it publishes #{actual.empty? ? "nothing" : actual.join(", ")}.\n\n#{docker_situation}#{transcript}"
    end
  end

  def assert_publishes_nothing(name)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    actual = c["ports"].map { |p| "#{p["host"]}:#{p["container"]}" }
    assert actual.empty?, "Expected #{name} to publish no port; it publishes #{actual.join(", ")}.\n\n#{docker_situation}#{transcript}"
  end

  # No container farmy started bind-mounts anything outside the containers folder (the test's folder): a
  # path of the control container is not on the host, and the daemon resolves bind sources there.
  def assert_binds_within_workspace
    outside = docker_state["containers"].flat_map { |n, c| (c["binds"] || []).reject { |b| b["source"].start_with?("#{dir}/") || b["source"] == dir }.map { |b| "#{n}: #{b["source"]} at #{b["target"]}" } }
    assert outside.empty?, "Expected every bind mount to come from inside the containers folder #{dir} (the daemon resolves bind sources on the host, and only that folder is there); these do not: #{outside.join("; ")}.\n\n#{docker_situation}#{transcript}"
  end

  def assert_init(*names)
    names.each do |name|
      c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
      assert c["init"], "Expected #{name} to run with an init process (init: true), and it does not.\n\n#{docker_situation}#{transcript}"
    end
  end

  def assert_env(name, key, value = nil)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    assert c["env"].key?(key), "Expected #{name} to have #{key} in its environment. It has: #{c["env"].keys.sort.join(", ")}.\n\n#{docker_situation}#{transcript}"
    assert value === c["env"][key], "Expected #{key} in #{name} to #{value.is_a?(Regexp) ? "match" : "be"} #{value.inspect}, got #{c["env"][key].inspect}.\n\n#{docker_situation}#{transcript}" if value
  end

  def refute_env(name, key)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    refute c["env"].key?(key), "Expected #{name} not to have #{key} in its environment, and it has #{key}=#{c["env"][key]}.\n\n#{docker_situation}#{transcript}"
  end

  def assert_mounted(name, volume, at: nil)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    mounted = c["volumes"].map { |v| v["name"] }
    assert mounted.include?(volume), "Expected the volume #{volume} to be mounted in #{name}; mounted: #{mounted.empty? ? "no volume" : mounted.join(", ")}.\n\n#{docker_situation}#{transcript}"
    return unless at
    target = c["volumes"].find { |v| v["name"] == volume }["target"]
    assert target == at, "Expected the volume #{volume} to be mounted in #{name} at #{at}, and it is mounted at #{target}.\n\n#{docker_situation}#{transcript}"
  end

  def refute_mounted(name, volume)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    refute c["volumes"].any? { |v| v["name"] == volume }, "Expected the volume #{volume} not to be mounted in #{name}, and it is.\n\n#{docker_situation}#{transcript}"
  end

  def assert_image(name, image)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    assert c["image"] == image, "Expected #{name} to run the image #{image}, and it runs #{c["image"]}.\n\n#{docker_situation}#{transcript}"
  end

  def assert_network(name, network)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    assert c["networks"].include?(network), "Expected #{name} to be on the network #{network}; it is on #{c["networks"].join(", ")}.\n\n#{docker_situation}#{transcript}"
  end

  def assert_volume(*names)
    names.each { |name| assert docker_state["volumes"].key?(name), "Expected a Docker volume named #{name}.\n\n#{docker_situation}#{transcript}" }
  end

  def refute_volume(*names)
    names.each { |name| refute docker_state["volumes"].key?(name), "Expected no Docker volume named #{name}.\n\n#{docker_situation}#{transcript}" }
  end

  def assert_ran_in(name, text, in: nil, as: nil)
    where = binding.local_variable_get(:in)
    execs = docker_state["execs"].select { |e| e["container"] == name }
    hits = execs.select { |e| ran_text?(e, text) }
    assert !hits.empty?, "Expected a command matching #{text.inspect} to have been run in #{name} with docker exec.\n\n#{docker_situation}#{transcript}"
    return if as.nil? && where.nil?
    same = hits.select { |e| (as.nil? || e["user"] == as) && (where.nil? || e["workdir"] == where) }
    ran = hits.map { |e| "as #{e["user"] || "(the image's default user)"} in #{e["workdir"] || "(the image's default folder)"}" }.uniq.join("; ")
    assert !same.empty?, "Expected the command matching #{text.inspect} to have been run in #{name}#{" as #{as}" if as}#{" in the folder #{where}" if where} (on one execution); it ran #{ran}.\n\n#{docker_situation}#{transcript}"
  end

  def refute_ran_in(name, text)
    execs = docker_state["execs"].select { |e| e["container"] == name }
    refute execs.any? { |e| ran_text?(e, text) }, "Expected no command matching #{text.inspect} to have been run in #{name}, and one was.\n\n#{docker_situation}#{transcript}"
  end

  # The container is started after that compose service of its project (depends_on); with healthy: true it
  # waits for the service to be healthy (condition service_healthy), else only for it to be started.
  def assert_waits_for(name, service, healthy: false)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    deps = c["depends"] || {}
    assert deps.key?(service), "Expected #{name} to be started after the compose service #{service} (depends_on); it depends on #{deps.empty? ? "nothing" : deps.keys.join(", ")}.\n\n#{docker_situation}#{transcript}"
    want = healthy ? "service_healthy" : "service_started"
    assert deps[service] == want, "Expected #{name} to wait for #{service} to be #{healthy ? "healthy" : "started"} (depends_on condition #{want}); it waits for #{deps[service]}.\n\n#{docker_situation}#{transcript}"
  end

  # The container's main process (the image's ENTRYPOINT and CMD with the docker run line, as Docker
  # composes them) does not start with that program.
  def refute_process(name, program)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    process = c["process"] || c["command"]
    refute process.first == program, "Expected the container #{name} to run a process that keeps it up, not #{program} (a command-line tool, which exits); its process, entrypoint included, is: #{process.join(" ")}.\n\n#{docker_situation}#{transcript}"
  end

  # The container came from that service of its compose file (the name the app reaches it by).
  def assert_compose_service(name, service)
    c = container(name) or flunk("Expected a container named #{name}.\n\n#{docker_situation}#{transcript}")
    assert c["service"] == service, "Expected #{name} to be the compose service #{service}, and it is #{c["service"].inspect}.\n\n#{docker_situation}#{transcript}"
  end

  # The commands ran in that order (each matched by text, as assert_ran_in does).
  def assert_ran_in_order(name, *texts)
    execs = docker_state["execs"].select { |e| e["container"] == name }
    positions = texts.map do |text|
      hit = execs.find { |e| ran_text?(e, text) }
      assert hit, "Expected a command matching #{text.inspect} to have been run in #{name} with docker exec.\n\n#{docker_situation}#{transcript}"
      hit["seq"]
    end
    assert positions == positions.sort, "Expected the commands to run in #{name} in this order: #{texts.map(&:inspect).join(", ")}; they ran in another.\n\n#{docker_situation}#{transcript}"
  end

  # Some image Docker was asked to build matches all of: the --target, the files in its context, a text in its Dockerfile.
  def assert_built(target: nil, files: nil, dockerfile_includes: nil, with_arg: nil, file_content: nil)
    builds = docker_state["images"].values.sort_by { |i| i["seq"].to_i }
    found = builds.reverse.find do |i|
      (target.nil? || i["target"] == target) && (files || []).all? { |f| i["files"].include?(f) } &&
        (dockerfile_includes.nil? || i["dockerfile"].include?(dockerfile_includes)) &&
        (with_arg.nil? || i["args"].include?(with_arg)) &&
        (file_content.nil? || (i["file_hashes"] || {})[file_content.first] == Digest::SHA256.hexdigest(file_content.last))
    end
    wanted = [target && "--target #{target}", files && "the files #{files.join(", ")} in the context",
              dockerfile_includes && "a Dockerfile including #{dockerfile_includes.inspect}",
              with_arg && "--build-arg #{with_arg}", file_content && "#{file_content.first} in the context holding the given text"].compact.join(", ")
    assert found, "Expected an image to have been built with #{wanted}.\n\n#{builds_situation}#{transcript}"
  end

  def builds_situation
    builds = docker_state["images"].reject { |tag, _| tag.start_with?("<none>") }
    return "  No image was built.\n\n#{docker_situation}" if builds.empty?
    lines = ["  Images built, in order:"]
    builds.sort_by { |_, i| i["seq"].to_i }.each do |tag, i|
      lines << "    #{tag}: #{i["target"] ? "--target #{i["target"]}" : "no --target"}; args: #{i["args"].join(" ")}; context: #{i["files"].empty? ? "nothing" : i["files"].first(12).join(", ")}"
      lines << "      Dockerfile: #{i["dockerfile"].lines.first(3).map(&:strip).join(" / ")}"
    end
    "#{lines.join("\n")}\n\n#{docker_situation}"
  end

  def assert_started_before(first, second)
    a, b = container(first), container(second)
    assert a && b, "Expected containers named #{first} and #{second}.\n\n#{docker_situation}#{transcript}"
    assert a["started_seq"] < b["started_seq"], "Expected #{first} to be started before #{second}, and it was started after.\n\n#{docker_situation}#{transcript}"
  end

  # A command matches by its shell line, or by its words joined with spaces (so that one run through
  # `sh -c "…"` is still found by its text).
  def ran_text?(exec, text)
    [Shellwords.join(exec["command"]), exec["command"].join(" ")].any? { |c| text === c || c.include?(text.to_s) }
  end

  # The real Docker, outside the fake on the PATH: for the integration tests only.
  def real_docker?
    out, status = Open3.capture2e({ "PATH" => ENV.fetch("PATH").split(":").reject { |p| p == FAKES }.join(":") }, "docker", "info")
    status.success? && !out.include?("Operating System: fake")
  rescue Errno::ENOENT
    false
  end

  def real_docker(*args)
    out, = Open3.capture2e({ "PATH" => ENV.fetch("PATH").split(":").reject { |p| p == FAKES }.join(":") }, "docker", *args)
    out
  end

  def after_teardown
    super
    if @scratch
      # A killed fake container cannot restore chmod-based read-only mounts in ensure.
      # Assertions have finished and controllers are stopped; make only fixture directories
      # removable now. lstat avoids following home/mount symlinks outside their own entries.
      pending = [@scratch]
      until pending.empty?
        path = pending.pop
        stat = File.lstat(path) rescue nil
        next unless stat&.directory?
        File.chmod(stat.mode | 0o700, path)
        pending.concat(Dir.children(path).map { |entry| File.join(path, entry) })
      end
      FileUtils.remove_entry(@scratch)
    end
  end

  private

  def farmy_env
    # the control container's holder of unlocking values listens on a socket of the test's own, gone after it
    env = { "PATH" => "#{store_bin}:#{FAKES}:#{ENV.fetch("PATH")}", "FAKE_DOCKER_JOURNAL" => docker_journal, "FARMY_BUILD" => "1",
            "FARMY_HOLD_SOCKET" => File.join(scratch, "hold", "hold.sock") }.merge(store_env).merge(@fake_env || {})
    env["FAKE_DOCKER_DOWN"] = "1" if @docker_down
    env
  end

  def scratch = @scratch ||= Dir.mktmpdir("farmy-")
  def docker_journal = File.join(scratch, "docker").tap { |d| FileUtils.mkdir_p(d) }
  def remote_dir = File.join(scratch, "remote").tap { |d| FileUtils.mkdir_p(d) }

  def remote_git(*args)
    output, status = Open3.capture2e(Workspace::GIT_ENV, "git", *args)
    raise "git #{args.join(" ")} failed while preparing the git host:\n#{output}" unless status.success?
    output
  end

  def docker_state
    file = File.join(docker_journal, "state.json")
    return { "containers" => {}, "images" => {}, "volumes" => {}, "networks" => {}, "execs" => [], "runs" => [], "unhandled" => [] } unless File.exist?(file)
    JSON.parse(File.read(file))
  end

  def container(name) = docker_state["containers"][name]

  def change_docker_state
    file = File.join(docker_journal, "state.json")
    File.open(File.join(docker_journal, "state.lock"), "a+") do |lock|
      lock.flock(File::LOCK_EX)
      state = docker_state
      yield state
      temporary = "#{file}.#{Process.pid}.tmp"
      File.write(temporary, JSON.pretty_generate(state))
      File.rename(temporary, file)
    end
  end

  def docker_situation
    state = docker_state
    lines = ["  Docker, as the fake on the PATH saw it:"]
    if state["containers"].empty?
      lines << "    containers: none"
    else
      state["containers"].sort_by { |_, c| c["started_seq"].to_i }.each do |name, c|
        ports = c["ports"].map { |p| "#{p["host"]}:#{p["container"]}" }
        lines << "    #{name}: #{c["state"]}, image #{c["image"]}#{", ports #{ports.join(" ")}" unless ports.empty?}" \
                 "#{", init" if c["init"]}#{", volumes #{c["volumes"].map { |v| v["name"] }.join(" ")}" unless c["volumes"].empty?}"
        lines << "      env: #{c["env"].sort.map { |k, v| "#{k}=#{v}" }.join(" ")}" unless c["env"].empty?
      end
    end
    lines << "    volumes: #{state["volumes"].empty? ? "none" : state["volumes"].keys.sort.join(", ")}"
    built = state["images"].reject { |tag, _| tag.start_with?("<none>") }
    lines << "    images built: #{built.map { |tag, i| "#{tag}#{" (target #{i["target"]})" if i["target"]}" }.join(", ")}" unless built.empty?
    unless state["execs"].empty?
      lines << "    commands run in containers:"
      state["execs"].last(12).each { |e| lines << "      #{e["container"]}: #{Shellwords.join(e["command"])}#{" (stdin: #{e["stdin"].bytesize} bytes)" if e["stdin"] && !e["stdin"].empty?}" }
    end
    lines << "    unhandled by the fake: #{state["unhandled"].uniq.join("; ")}" unless state["unhandled"].empty?
    calls = File.join(docker_journal, "calls.log")
    if File.exist?(calls)
      all = File.readlines(calls, chomp: true)
      lines << "  Every docker call, in order#{" (last 30 of #{all.size})" if all.size > 30}:"
      all.last(30).each { |call| lines << "    docker #{call}" }
    end
    lines.join("\n")
  end
end
