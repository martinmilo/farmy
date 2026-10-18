# Filesystem/OS capabilities for toolbox acceptance tests. The generated application scripts
# do the work: this fake does not decide which dotfiles or tool-data directories to link.
# Enabled only by an explicit test fixture, as the older fake does not execute app entrypoints.
require "open3"

def toolbox_enabled? = $state["toolbox_runtime"] == true

def toolbox_home(name)
  File.join(JOURNAL, "homes", name).tap do |path|
    FileUtils.rm_f(path) if File.symlink?(path) && !File.exist?(path)
    FileUtils.mkdir_p(path)
  end
end

# Tests prepare and observe a home through JOURNAL/homes/<container>. A real home volume
# remains its storage; keep that stable observation path as an alias of the mounted volume.
def toolbox_attach_home_volume(name, container)
  mount = Array(container["volumes"]).find { |entry| entry["target"] == "/home/dev" }
  return unless mount
  home = toolbox_home(name)
  source = toolbox_mount_source(mount)
  return if File.realpath(home) == File.realpath(source)
  if File.symlink?(home)
    FileUtils.rm_f(home)
  else
    Dir.children(home).each do |entry|
      destination = File.join(source, entry)
      fail_with("fake docker home fixture conflicts with mounted home at #{entry}") if File.exist?(destination) || File.symlink?(destination)
      FileUtils.mv(File.join(home, entry), destination)
    end
    Dir.rmdir(home)
  end
  File.symlink(source, home)
end

def toolbox_app_start(name, container)
  return unless toolbox_enabled? && container["service"] == "app"
  toolbox_attach_home_volume(name, container)
  home = toolbox_home(name)
  %w[.bashrc .zshrc .profile].each do |basename|
    path = File.join(home, basename)
    File.write(path, "# image skel #{basename}\n") unless File.exist?(path) || File.symlink?(path)
  end
end

def toolbox_mount_source(mount)
  path = File.join(volume_dir(mount["name"]), mount["subpath"].to_s)
  FileUtils.mkdir_p(path)
  path
end

def toolbox_mount_table(container, name)
  table = { "/home/dev" => toolbox_home(name) }
  Array(container["volumes"]).each do |mount|
    table[mount["target"]] = mount["target"] == "/home/dev" ? toolbox_home(name) : toolbox_mount_source(mount)
  end
  Array(container["binds"]).each { |mount| table[mount["target"]] = mount["source"] }
  table
end

def toolbox_expose_home_mounts(container, name)
  home = toolbox_home(name)
  Array(container["volumes"]).sort_by { |mount| mount["target"].to_s.length }.each do |mount|
    target = mount["target"].to_s
    next unless target.start_with?("/home/dev/")
    local = File.join(home, target.delete_prefix("/home/dev/"))
    source = toolbox_mount_source(mount)
    next if File.exist?(local) && File.realpath(local) == File.realpath(source)
    next if File.exist?(local) && !File.symlink?(local)
    FileUtils.mkdir_p(File.dirname(local))
    FileUtils.rm_f(local) if File.symlink?(local)
    File.symlink(source, local)
  end
end

# COPY is an image-building primitive. Expose only files actually copied by the Dockerfile;
# a script in the context but never included in the image cannot run in a fake container either.
def toolbox_image_files(container)
  image = find_image(container["image"]) || {}
  files = image["file_texts"] || {}
  installed = {}
  image["dockerfile"].to_s.gsub(/\\\n\s*/, " ").lines.each do |line|
    next unless line =~ /^\s*COPY\s+(.+)$/i
    arguments = Regexp.last_match(1).strip
    arguments = arguments.sub(/\A(?:--\S+\s+)+/, "")
    words = arguments.start_with?("[") ? JSON.parse(arguments) : Shellwords.split(arguments)
    destination = words.last
    words[0...-1].each do |source|
      if source == "." || source.end_with?("/")
        files.each do |relative, contents|
          next if source != "." && !relative.start_with?(source)
          installed[File.join(destination, source == "." ? relative : relative.delete_prefix(source))] = contents
        end
      elsif files[source]
        target = destination.end_with?("/") ? File.join(destination, File.basename(source)) : destination
        installed[target] = files[source]
      end
    end
  rescue JSON::ParserError, ArgumentError
    nil
  end
  installed
end

def toolbox_os_bin(name, platform, user)
  directory = File.join(JOURNAL, "os-bin", name).tap { |path| FileUtils.mkdir_p(path) }
  arch = platform["architecture"] == "arm64" ? "aarch64" : "x86_64"
  libc = platform["libc"] || "glibc"
  scripts = {
    "uname" => "#!/bin/sh\ncase \"$1\" in -m) echo #{arch};; -s) echo Linux;; *) /usr/bin/uname \"$@\";; esac\n",
    "ldd" => "#!/bin/sh\necho '#{libc == 'musl' ? 'musl libc (aarch64) Version 1.2.5' : 'ldd (GNU libc) 2.36'}'\n",
    "id" => "#!/bin/sh\ncase \"$1\" in -un) echo #{user == 'dev' ? 'dev' : 'root'};; -u) echo #{user == 'dev' ? 1001 : 0};; -gn) echo #{user == 'dev' ? 'dev' : 'root'};; -g) echo #{user == 'dev' ? 1001 : 0};; *) /usr/bin/id \"$@\";; esac\n"
  }
  if $state["entrypoint_runtime"]
    scripts["id"] = <<~SH
      #!/bin/sh
      case "$1" in
        -u) echo "${FAKE_ENTRYPOINT_UID:-#{user == 'dev' ? 1001 : 0}}";;
        -un) if [ "${FAKE_ENTRYPOINT_UID:-#{user == 'dev' ? 1001 : 0}}" = 0 ]; then echo root; else echo dev; fi;;
        -g) echo 1001;; -gn) echo dev;; *) /usr/bin/id "$@";;
      esac
    SH
    %w[chown sshd ssh-keygen].each { |name| scripts[name] = "#!/bin/sh\nexit 0\n" }
    scripts["sleep"] = "#!/bin/sh\ncase \"$1\" in infinity) exit 0;; *) exec /bin/sleep \"$@\";; esac\n"
    scripts["tail"] = "#!/bin/sh\ncase \"$*\" in '-f /dev/null'|'-F /dev/null') exit 0;; *) exec /usr/bin/tail \"$@\";; esac\n"
    scripts["curl"] = "#!/bin/sh\ncase \"$*\" in *'http://keys:9181/-/health'*) exit 0;; *) exec /usr/bin/curl \"$@\";; esac\n"
    %w[gosu su-exec].each do |name|
      scripts[name] = "#!/bin/sh\nshift\nexport FAKE_ENTRYPOINT_UID=1001 USER=dev LOGNAME=dev\nexec \"$@\"\n"
    end
  end
  real_git = ENV.fetch("PATH").split(":").map { |part| File.join(part, "git") }.find { |path| File.executable?(path) && !File.directory?(path) }
  scripts["git"] = <<~RUBY
    #!#{RbConfig.ruby}
    require "json"
    arguments = ARGV.dup
    remaining = arguments.dup
    valued = %w[-C -c --git-dir --work-tree --namespace --config-env --super-prefix]
    operation = nil
    until remaining.empty?
      word = remaining.shift
      if valued.include?(word)
        remaining.shift
      elsif !word.start_with?("-")
        operation = word
        break
      end
    end
    if %w[clone pull fetch].include?(operation)
      record = { "operation" => operation, "destination" => arguments.join(" "), "argv" => arguments, "cwd" => Dir.pwd }
      File.open(#{File.join(JOURNAL, "toolbox-git-operations.jsonl").dump}, "a") do |log|
        log.flock(File::LOCK_EX)
        log.puts(JSON.generate(record))
      end
    end
    exec(#{real_git.to_s.dump}, *arguments)
  RUBY
  scripts.each { |basename, text| path = File.join(directory, basename); File.write(path, text); File.chmod(0755, path) }
  directory
end

# Children cannot acquire Docker's state lock while the parent waits for them. Their
# append-only Git journal has its own lock and is incorporated after the command exits.
def toolbox_collect_git_operations
  path = File.join(JOURNAL, "toolbox-git-operations.jsonl")
  return unless File.file?(path)
  File.open(path) do |log|
    log.seek($state.fetch("toolbox_git_log_offset", 0))
    log.each_line { |line| ($state["toolbox_git_operations"] ||= []) << JSON.parse(line) }
    $state["toolbox_git_log_offset"] = log.pos
  end
end

def toolbox_readonly_paths(container)
  Array(container["volumes"]).select { |mount| mount["ro"] }.map { |mount| toolbox_mount_source(mount) } +
    Array(container["binds"]).select { |mount| mount["ro"] }.map { |mount| mount["source"] }
end

def toolbox_protect(paths)
  modes = {}
  paths.each do |root|
    ([root] + Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)).uniq.each do |path|
      next if File.symlink?(path) || !File.exist?(path)
      canonical = File.realpath(path)
      next if modes.key?(canonical)
      modes[canonical] = File.stat(canonical).mode & 07777
      File.chmod(modes[canonical] & ~0222, canonical)
    end
  end
  modes
end

def toolbox_restore(modes)
  modes.each { |path, mode| File.chmod(mode, path) if File.exist?(path) && !File.symlink?(path) }
end

def toolbox_prepare_process(container, name, command, user:, workdir: nil, overrides: {})
  toolbox_attach_home_volume(name, container)
  toolbox_expose_home_mounts(container, name)
  table = toolbox_mount_table(container, name)
  copied = toolbox_image_files(container)
  image_root = File.join(JOURNAL, "app-images", name)
  platform = ($state["app_platforms"] || {})[name] || { "architecture" => "amd64", "libc" => "glibc" }
  os_bin = toolbox_os_bin(name, platform, user)
  # Every exec sees the container's system files, including root-only configuration
  # refreshes after dotfiles installation. Never read or write the test host's /etc.
  %w[/etc /run /var/log /var/lib].each do |path|
    table[path] ||= File.join(image_root, path.delete_prefix("/"))
    FileUtils.mkdir_p(table.fetch(path))
  end
  FileUtils.mkdir_p(File.join(table.fetch("/etc"), "ssh"))
  if $state["entrypoint_runtime"]
    %w[/usr/sbin/sshd /usr/bin/ssh-keygen].each { |path| table[path] = File.join(os_bin, File.basename(path)) }
  end
  copied.each_key { |path| table[path] = File.join(image_root, path.delete_prefix("/")) }
  # Runtime scripts may invoke one another through PATH as well as absolute paths.
  copied.each do |path, text|
    mapped = table.fetch(path)
    FileUtils.mkdir_p(File.dirname(mapped))
    File.write(mapped, map_paths(text, table))
    File.chmod(0755, mapped) if path.end_with?(".sh") || text.start_with?("#!")
  end
  path = [os_bin, *copied.keys.map { |file| File.dirname(table.fetch(file)) }.uniq, ENV["PATH"]].join(":")
  env = git_env.merge("HOME" => toolbox_home(name), "USER" => user, "LOGNAME" => user, "PATH" => path)
  env.merge!("GIT_CONFIG_GLOBAL" => nil, "GIT_CONFIG_NOSYSTEM" => nil,
    "GIT_CONFIG_SYSTEM" => File.join(table.fetch("/etc"), "gitconfig"))
  (container["env"] || {}).merge(overrides).each { |key, value| env[key] = map_paths(value.to_s, table) }
  argv = command.map { |word| map_paths(word, table) }
  cwd = workdir ? map_paths(workdir, table) : toolbox_home(name)
  [env, argv, cwd, table]
end

def toolbox_exec(opts, command, container, record)
  return unless toolbox_enabled? && container["service"] == "app"
  text = command.join(" ")
  return if text.include?("/proc/") || text.include?(".farmy-clone") || text.match?(/\bps\b.*\b(?:aux|eo)\b/)
  name = container_name_of(container)
  # Opening an interactive terminal is observed as a Docker exec, not consumed by this fake.
  if %w[zsh bash sh].include?(File.basename(command.first.to_s)) && command.drop(1).all? { |word| word.start_with?("-") } && !command.include?("-c")
    record["exit"] = 0
    exit 0
  end
  user = %w[dev 1001 1001:1001].include?(value(opts, "u", "user").to_s) ? "dev" : "root"
  env, argv, cwd, = toolbox_prepare_process(container, name, command, user: user,
    workdir: value(opts, "w", "workdir"), overrides: record["env"] || {})
  readonly = toolbox_protect(toolbox_readonly_paths(container))
  begin
    out, err, status = Open3.capture3(env, *argv, stdin_data: record["stdin"].to_s, chdir: cwd)
    print out
    $stderr.print err
    record["exit"] = status.exitstatus || 128 + status.termsig
  rescue Errno::ENOENT => error
    $stderr.puts "docker exec: #{error.message}"
    record["exit"] = 127
  ensure
    toolbox_restore(readonly)
    toolbox_collect_git_operations
  end
  exit record["exit"]
end

def toolbox_authenticated_git?(configuration, env, container)
  needed = configuration["secret"]
  route = env.select { |key, _| key.start_with?("GIT_CONFIG_") || %w[DEV_GIT_ROUTES DEV_GIT_SSH_ROUTES SSH_AUTH_SOCK GIT_SSH_COMMAND].include?(key) }.values.join(" ")
  return false if route.empty?
  return false if configuration["auth"] == "ssh" && !route.include?("ssh") && !env["SSH_AUTH_SOCK"]
  return false if configuration["auth"] == "token" && !route.match?(%r{https?://[^\s]*/(?:dotfiles|git)/?})
  brokers = containers.select { |_, candidate| candidate["service"] == "keys" && !(Array(candidate["networks"]) & Array(container["networks"])).empty? }
  brokers.any? do |name, broker|
    $state["execs"].any? do |entry|
      next false unless entry["container"] == name && entry["command"].include?("load") && entry["seq"].to_i > broker["started_seq"].to_i
      payload = JSON.parse(entry["stdin"].to_s) rescue {}
      payload.fetch("secrets", {}).key?(needed)
    end
  end
end

def toolbox_git_process(container, command, env, table)
  text = command.join(" ")
  operands = text + "\n" + env.values.join("\n")
  (($state["git_hosts"] || {})).each do |url, configuration|
    addresses = [url] + Array(configuration["aliases"])
    next unless addresses.any? { |address| operands.include?(address) }
    authenticated = toolbox_authenticated_git?(configuration, env, container)
    ($state["toolbox_git_requests"] ||= []) << { "url" => url, "auth" => configuration["auth"], "authenticated" => authenticated }
    fail_with("fatal: could not authenticate to private dotfiles repository through its #{configuration['auth']} route") unless authenticated
    addresses.each do |address|
      command = command.map { |word| word.gsub(address, configuration.fetch("local_url")) }
      env.transform_values! { |word| word&.gsub(address, configuration.fetch("local_url")) }
    end
  end
  command.map { |word| map_paths(word, table) }
end

# A write-authorized helper owns clone/pull. Execute its ordinary shell/git command, with Docker
# mounts mapped to real directories, and the optional fake remote authenticating at the boundary.
def toolbox_run(opts, process, record)
  return unless toolbox_enabled? && record.fetch("volumes", []).include?("farmy-shared")
  return unless %w[dotfiles git].include?(record.dig("labels", "farmy.role"))
  mounts = run_mounts(opts)
  container = { "image" => record["image"], "volumes" => mounts, "binds" => record["binds"],
    "env" => record["env"], "networks" => record["networks"] }
  name = record["name"] || "dotfiles-update"
  user = run_uid(opts) == "1001" ? "dev" : "root"
  env, argv, cwd, table = toolbox_prepare_process(container, name, process, user: user, workdir: value(opts, "w", "workdir"))
  argv = toolbox_git_process(container, argv, env, table)
  readonly = toolbox_protect(toolbox_readonly_paths(container))
  begin
    out, err, status = Open3.capture3(env, *argv, stdin_data: record["stdin"].to_s, chdir: cwd)
    print out
    $stderr.print err
    record["exit"] = status.exitstatus || 128 + status.termsig
  rescue Errno::ENOENT => error
    $stderr.puts "docker run: #{error.message}"
    record["exit"] = 127
  ensure
    toolbox_restore(readonly)
    toolbox_collect_git_operations
  end
  exit record["exit"]
end
