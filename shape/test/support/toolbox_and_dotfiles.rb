# Public toolbox build inputs and the developer home, observed through Docker's boundary.
require "socket"
require "uri"
require "timeout"

module ToolboxAndDotfiles
  TOOL_VENDORS = {
    "neovim" => "neovim/neovim", "ripgrep" => "BurntSushi/ripgrep", "fd" => "sharkdp/fd",
    "fzf" => "junegunn/fzf", "bat" => "sharkdp/bat", "lazygit" => "jesseduffield/lazygit",
    "delta" => "dandavison/delta", "jq" => "jqlang/jq"
  }.freeze
  COUNTER_PINS = {
    "1.0.0" => {
      "linux-amd64-glibc" => "f5dc45b7d71fff5da9e8bc92314e3e4ea01d42e0e5de90b7ece9feeba39c8f1d",
      "linux-arm64-glibc" => "233db563f89de62d81d6838a7fa24d9ea9eae6570bbd9bdf4de464d48ba281c7",
      "linux-amd64-musl" => "19ce30bedeaa392dcf85a58e426db384a18e66f7a048268c23fabf35702bcd4c",
      "linux-arm64-musl" => "ab83b69af5ce56da582975a0ce91c4e69e55a242ed0d695ebb93b6c49f5127f2"
    },
    "2.0.0" => {
      "linux-amd64-glibc" => "29eb08cac1810a7349f743908e5bd56ccd7e071b33226ea7c51bda900645d2b0",
      "linux-arm64-glibc" => "b65b0d2d4c41cbffca68dc255e952b7e50d9ad525bf15def4d9db8fee82a963e",
      "linux-amd64-musl" => "b99cf09f2883322accda97faa587362946efeebf228feb766e18e3982ecf06de",
      "linux-arm64-musl" => "d29ceabe164365f8efd2275f6ec57ea0a5cddeba334d52446b97e99563605446"
    }
  }.freeze

  def toolbox_workspace
    workspace "workshop"
    settings
    %w[shop notes toolkit].each { |name| write_file "services/#{name}.yml", "repo: none\nimage: debian:bookworm-slim\n" }
  end

  def select_tools(*names, service: nil, packages: nil)
    path = service ? "services/#{service}.yml" : "farmy.yml"
    data = File.file?(File.join(dir, path)) ? YAML.safe_load(read_file(path)) || {} : {}
    data["tools"] = names unless names.empty?
    data["packages"] = packages if packages
    write_file path, YAML.dump(data)
  end

  def configure_toolbox(**fields)
    data = File.file?(File.join(dir, "farmy.yml")) ? YAML.safe_load(read_file("farmy.yml")) || {} : {}
    fields.each { |key, value| data[key.to_s] = value }
    write_file "farmy.yml", YAML.dump(data)
  end

  def counter_catalogue(version: "1.0.0", selected: true, missing: nil, bad_checksum: false)
    start_tool_releases unless @tool_release_server
    entry = counter_entry(version)
    entry["artifacts"].delete(missing) if missing
    entry["artifacts"]["linux-amd64-glibc"]["sha256"] = "0" * 64 if bad_checksum
    configure_toolbox tool_catalogue: { "counter" => entry }
    select_tools "counter" if selected
    note_situation "counter #{version} has raw official-style fixture assets for both architectures and libcs#{", missing #{missing}" if missing}#{", wrong amd64 glibc checksum" if bad_checksum}."
  end

  def counter_entry(version)
    {
      "version" => version,
      "releases" => { "kind" => "github", "repo" => "acme/counter", "api" => @tool_release_url,
        "assets" => COUNTER_PINS.fetch(version).keys.to_h { |platform| [platform, "counter-{version}-#{platform}"] } },
      "artifacts" => COUNTER_PINS.fetch(version).to_h { |platform, checksum| [platform,
        { "url" => "#{@tool_release_url}/assets/counter-#{version}-#{platform}", "sha256" => checksum, "format" => "raw" }] },
      "install" => { "apt" => 'install -D -m0755 "$ARCHIVE" "$DESTDIR/usr/local/bin/counter"',
        "apk" => 'install -D -m0755 "$ARCHIVE" "$DESTDIR/usr/local/bin/counter"' }
    }
  end

  def counter_release_missing(platform, tool: "counter")
    @tool_release_missing = platform
    @tool_release_missing_tool = tool
    note_situation "#{tool} 2.0.0's release is missing #{platform}; its resolver declares that combination required."
  end

  def counter_release_corrupt(platform)
    @tool_release_corrupt = platform
    note_situation "counter 2.0.0's #{platform} download disagrees with its published SHA-256."
  end

  def write_counter_lock(version: "1.0.0")
    write_file "tools.lock", YAML.dump("version" => 1, "tools" => { "counter" => counter_entry(version) })
  end

  def two_counter_tools_with_lock
    counter_catalogue
    data = YAML.safe_load(read_file("farmy.yml"))
    gauge = counter_entry("1.0.0")
    gauge["releases"]["repo"] = "acme/gauge"
    data["tool_catalogue"]["gauge"] = gauge
    data["tools"] = %w[counter gauge]
    write_file "farmy.yml", YAML.dump(data)
    write_file "tools.lock", YAML.dump("version" => 1, "tools" => data.fetch("tool_catalogue"))
    note_situation "Both counter and gauge are selected and locked at 1.0.0; counter has a complete stable 2.0.0 release."
  end

  def ripgrep_version_override(complete:)
    start_tool_releases unless @tool_release_server
    replacement = counter_entry("1.0.0").fetch("artifacts")
    replacement = replacement.slice("linux-amd64-glibc") unless complete
    configure_toolbox tools: ["ripgrep"], tool_catalogue: { "ripgrep" => {
      "version" => "99.0.0", "artifacts" => replacement,
      "install" => { "apt" => 'install -D -m0755 "$ARCHIVE" "$DESTDIR/usr/local/bin/rg"',
        "apk" => 'install -D -m0755 "$ARCHIVE" "$DESTDIR/usr/local/bin/rg"' }
    } }
    note_situation "ripgrep's explicit 99.0.0 override supplies #{complete ? 'all four architecture/libc fixture artifacts' : 'only linux-amd64-glibc; other artifacts must not be inherited from the shipped version'}."
  end

  def remember_locked_tool(name)
    (@remembered_locked_tools ||= {})[name] = YAML.safe_load(read_file("tools.lock")).fetch("tools").fetch(name)
  end

  def assert_locked_tool_unchanged(name)
    assert_equal @remembered_locked_tools.fetch(name), YAML.safe_load(read_file("tools.lock")).fetch("tools").fetch(name),
      "An explicit bump must preserve every field of the unselected #{name} lock entry.#{transcript}"
  end

  def stale_ripgrep_lock
    write_file "tools.lock", YAML.dump("version" => 1, "tools" => { "ripgrep" => {
      "version" => "15.1.0", "artifacts" => {
        "linux-amd64-glibc" => { "url" => "https://github.com/BurntSushi/ripgrep/releases/download/15.1.0/ripgrep-15.1.0-x86_64-unknown-linux-musl.tar.gz", "sha256" => "1" * 64, "format" => "tar.gz" },
        "linux-arm64-glibc" => { "url" => "https://github.com/BurntSushi/ripgrep/releases/download/15.1.0/ripgrep-15.1.0-aarch64-unknown-linux-gnu.tar.gz", "sha256" => "2" * 64, "format" => "tar.gz" }
      }, "install" => { "apt" => 'tar -xf "$ARCHIVE" -C "$DESTDIR"' }
    } })
  end

  def assert_tool_catalogue
    entries = JSON.parse(stdout)
    assert entries.is_a?(Hash), "Expected toolbox list --json to map tool names to resolved entries.#{transcript}"
    TOOL_VENDORS.each do |name, repository|
      entry = entries[name]
      assert entry.is_a?(Hash), "Expected shipped tool #{name} in toolbox list --json.#{transcript}"
      assert_match(/\Av?\d+\.\d+(?:\.\d+)?[^\s]*\z/, entry["version"].to_s, "Expected #{name} to have a pinned version.#{transcript}")
      assert_equal repository.downcase, entry.dig("releases", "repo").to_s.downcase, "Expected #{name} to resolve official releases from #{repository}.#{transcript}"
      %w[amd64 arm64].each do |arch|
        artifact = entry.dig("artifacts", "linux-#{arch}-glibc")
        assert artifact.is_a?(Hash), "Expected #{name} to ship a linux-#{arch}-glibc artifact.#{transcript}"
        assert_match(%r{\Ahttps://github\.com/#{Regexp.escape(repository)}/releases/download/}i, artifact["url"].to_s, "Expected #{name}'s #{arch} artifact to come from its official prebuilt release.#{transcript}")
        assert_match(/\A[0-9a-f]{64}\z/, artifact["sha256"].to_s, "Expected #{name}'s #{arch} SHA-256 pin, never a moving URL without a checksum.#{transcript}")
      end
    end
    assert Gem::Version.new(entries.fetch("ripgrep").fetch("version").delete_prefix("v")) >= Gem::Version.new("15.2"), "Expected shipped ripgrep >=15.2 for arm64 musl.#{transcript}"
    musl = entries.dig("ripgrep", "artifacts", "linux-arm64-musl")
    assert musl.is_a?(Hash), "Expected ripgrep's first-class arm64 musl release pin, the reason for the >=15.2 minimum.#{transcript}"
    assert_match(%r{\Ahttps://github\.com/BurntSushi/ripgrep/releases/download/.*(?:aarch64|arm64).*musl}, musl["url"].to_s,
      "Expected the official arm64 musl ripgrep build, never a glibc binary renamed as compatible.#{transcript}")
    assert_match(/\A[0-9a-f]{64}\z/, musl["sha256"].to_s, "Expected the arm64 musl ripgrep checksum pin.#{transcript}")
  rescue JSON::ParserError => e
    flunk "Expected toolbox list --json to return a JSON catalogue: #{e.message}.#{transcript}"
  end

  def toolbox_build(service)
    build = docker_state["images"]["farmy/#{service}:dev"]
    assert build, "Expected the toolbox image farmy/#{service}:dev to be built.#{transcript}"
    build
  end

  # The value an ENV instruction after the last FROM of the service's toolbox Dockerfile gives name
  # (ENV NAME=value …, or the legacy ENV NAME value), nil when none does.
  def toolbox_image_env(service, name)
    lines = toolbox_build(service).fetch("dockerfile").gsub(/\\\r?\n\s*/, " ").lines
    final = lines.drop(lines.rindex { |line| line =~ /\A\s*FROM\s/i } || 0)
    final.grep(/\A\s*ENV\s/i).reverse_each do |line|
      body = line.sub(/\A\s*ENV\s+/i, "").strip
      pairs = body.include?("=") ? body.scan(/(\w+)=("[^"]*"|'[^']*'|\S+)/) : [body.split(/\s+/, 2)]
      found = pairs.reverse.find { |key, _| key == name }
      return found.last.to_s.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'") if found
    end
    nil
  end

  def assert_toolbox_image_env(service, name, value)
    got = toolbox_image_env(service, name)
    assert_equal value, got, "Expected farmy's toolbox layer to set #{name}=#{value} for #{service}'s app image (an ENV instruction " \
                             "after the last FROM), so tools in every app image read and write UTF-8 whatever the base image or the " \
                             "user's own LANG; #{got ? "it sets #{name}=#{got}" : "it sets no #{name}"}.#{transcript}"
  end

  def toolbox_context(service, file)
    build = toolbox_build(service)
    text = (build["file_texts"] || {})[file]
    assert text, "Expected public toolbox build-context file #{file} for #{service}; got #{Array(build['files']).join(', ')}.#{transcript}"
    text
  end

  def assert_tools_selected(service, *names)
    entries = YAML.safe_load(toolbox_context(service, "tools.yml")) || {}
    assert_equal names.sort, entries.keys.sort, "Expected #{service}'s tools.yml to contain exactly the union of workspace and service tools #{names.join(', ')}.#{transcript}"
  end

  def assert_tool_downloads(service, architecture:, libc: "glibc", tools: TOOL_VENDORS.keys)
    build = toolbox_build(service)
    entries = YAML.safe_load(toolbox_context(service, "tools.yml")) || {}
    tools.each do |name|
      artifact = entries.dig(name, "artifacts", "linux-#{architecture}-#{libc}")
      assert artifact, "Expected #{name}'s pinned linux-#{architecture}-#{libc} URL and checksum in #{service}'s tools.yml.#{transcript}"
      %w[url sha256].each do |key|
        assert_includes build["dockerfile"], artifact.fetch(key), "Expected the toolbox Dockerfile to carry #{name}'s pinned #{architecture}/#{libc} #{key}, so the build is architecture-specific and immutable.#{transcript}"
      end
    end
    package_lines = build["dockerfile"].scan(/(?:apt-get|apk)\s+[^\n;&|]*(?:install|add)\s+[^\n;&|]*/).join(" ")
    refute_match(/\b(?:neovim|ripgrep|fd-find|fzf|bat|lazygit|git-delta|jq)\b/, package_lines, "Catalogue tool binaries must come from their pinned releases, not distro packages.#{transcript}")
  end

  def assert_tool_pin(service, name, version:, platform:, checksum:)
    entries = YAML.safe_load(toolbox_context(service, "tools.yml")) || {}
    assert_equal version, entries.dig(name, "version"), "Expected the resolved version for #{name} in the toolbox context.#{transcript}"
    assert_equal checksum, entries.dig(name, "artifacts", platform, "sha256"), "Expected #{name}'s #{platform} checksum to belong to that version.#{transcript}"
  end

  def install_captured_toolbox(service, architecture: "amd64", family: "apt")
    script = toolbox_context(service, "tools-install.sh")
    @tool_install_root = File.join(scratch, "installed-toolbox")
    stage = File.join(scratch, "toolbox-build")
    FileUtils.mkdir_p([stage, @tool_install_root])
    (toolbox_build(service)["file_texts"] || {}).each { |path, text| FileUtils.mkdir_p(File.dirname(File.join(stage, path))); File.write(File.join(stage, path), text) }
    File.write(File.join(stage, "tools-install.sh"), script)
    out, err, status = Open3.capture3({ "TARGETARCH" => architecture, "FARMY_BASE_FAMILY" => family, "DESTDIR" => @tool_install_root }, "sh", "tools-install.sh", chdir: stage)
    @finished = Commands::Finished.new("sh tools-install.sh (captured #{service} build context, TARGETARCH=#{architecture}, FARMY_BASE_FAMILY=#{family})", out, err, status.exitstatus, [])
  end

  def assert_installed_counter(version:, platform:)
    executable = File.join(@tool_install_root, "usr/local/bin/counter")
    assert File.executable?(executable), "Expected verified counter to be installed executable under DESTDIR/usr/local/bin.#{transcript}"
    out, status = Open3.capture2e(executable)
    assert status.success?, "Installed counter must execute: #{out}"
    assert_equal "counter #{version} #{platform}\n", out, "Expected the selected prebuilt artifact, not a wrong architecture/libc asset."
  end

  def refute_installed_counter
    refute File.exist?(File.join(@tool_install_root, "usr/local/bin/counter")), "A checksum failure must leave counter uninstalled.#{transcript}"
  end

  def assert_packages_selected(service, *names)
    assert_equal names.sort, toolbox_context(service, "packages.txt").lines.map(&:strip).reject(&:empty?).sort,
      "Expected workspace packages plus only #{service}'s own packages in its toolbox layer.#{transcript}"
  end

  def assert_package_installation(service, family:)
    build = toolbox_build(service)
    submitted = build["dockerfile"].to_s + "\n" + (build["file_texts"] || {}).values.join("\n")
    pattern = family == "apt" ? /apt-get\s+[^\n]*install/ : /apk\s+[^\n]*add/
    assert_match pattern, submitted, "Expected #{family} package installation in the submitted toolbox build inputs.#{transcript}"
    assert_includes build["dockerfile"], "packages.txt", "Expected the toolbox Dockerfile to consume packages.txt.#{transcript}"
  end

  def dotfiles_workspace(install: false)
    toolbox_workspace
    change_docker_state { |state| state["toolbox_runtime"] = true }
    @dotfiles_repo = File.join(scratch, "dotfiles-upstream.git")
    @dotfiles_checkout = File.join(scratch, "dotfiles-upstream-work")
    FileUtils.mkdir_p(@dotfiles_checkout)
    FileUtils.cp_r(File.join(TEST_ROOT, "fixtures", "dotfiles", "."), @dotfiles_checkout)
    File.chmod(0755, File.join(@dotfiles_checkout, "install.sh"))
    remote_git "init", "--quiet", "--bare", "--initial-branch=main", @dotfiles_repo
    remote_git "-C", @dotfiles_checkout, "init", "--quiet", "--initial-branch=main"
    remote_git "-C", @dotfiles_checkout, "add", "--all"
    remote_git "-C", @dotfiles_checkout, "commit", "--quiet", "-m", "Developer shell and editor configuration"
    remote_git "-C", @dotfiles_checkout, "remote", "add", "origin", "file://#{@dotfiles_repo}"
    remote_git "-C", @dotfiles_checkout, "push", "--quiet", "origin", "main"
    @dotfiles_revision = remote_git("-C", @dotfiles_checkout, "rev-parse", "HEAD").strip
    dotfiles = { "repo" => "file://#{@dotfiles_repo}" }
    dotfiles["install"] = "install.sh" if install
    configure_toolbox dotfiles: dotfiles
    note_situation "The dotfiles repository contains executable install.sh, .bashrc, .zshrc, .profile, .gitconfig, .config/nvim/init.lua, and forge metadata."
  end

  def private_dotfiles(transport)
    config = YAML.safe_load(read_file("farmy.yml"))
    upstream = transport == :ssh ? "ssh://git@git.example.com" : "https://git.example.com"
    url = "#{upstream}/dev/dotfiles.git"
    secret = transport == :ssh ? "GIT_SSH_KEY" : "GIT_TOKEN"
    route = { "secret" => secret, "upstream" => upstream, "auth" => transport == :ssh ? "ssh" : "basic", "git" => true }
    route["user"] = "x-access-token" unless transport == :ssh
    config["secrets"] = { "provider" => ["bin/provider"] }
    config["keys"] = { "dotfiles" => route }
    config["dotfiles"]["repo"] = url
    write_file "farmy.yml", YAML.dump(config)
    secrets_provider(**{ secret.to_sym => transport == :ssh ? fixture("keys/git_ed25519") : "frg_dotfiles_4f928cb" })
    change_docker_state { |state| (state["git_hosts"] ||= {})[url] = { "local_url" => "file://#{@dotfiles_repo}", "auth" => transport.to_s, "secret" => secret } }
    note_situation "The private dotfiles upstream requires its #{transport} broker route; the fake host forwards to the local bare Git repository only after authentication."
  end

  def advance_dotfiles
    @previous_dotfiles_revision = @dotfiles_revision
    File.write(File.join(@dotfiles_checkout, ".zshrc"), "export FARMY_DOTFILES_ZSH=updated\n")
    File.write(File.join(@dotfiles_checkout, ".inputrc"), "set editing-mode vi\n")
    remote_git "-C", @dotfiles_checkout, "add", "--all"
    remote_git "-C", @dotfiles_checkout, "commit", "--quiet", "-m", "Update the developer environment"
    remote_git "-C", @dotfiles_checkout, "push", "--quiet", "origin", "main"
    @dotfiles_revision = remote_git("-C", @dotfiles_checkout, "rev-parse", "HEAD").strip
    note_situation "The remote dotfiles now have another commit, changed .zshrc and a new .inputrc."
  end

  def dotfiles_upstream_unavailable
    FileUtils.mv(@dotfiles_repo, "#{@dotfiles_repo}.unavailable")
    note_situation "The upstream bare dotfiles repository is unavailable; the existing shared checkout remains usable."
  end

  def dotfiles_default_branch(name)
    remote_git "-C", @dotfiles_checkout, "branch", "-m", "main", name
    remote_git "-C", @dotfiles_checkout, "push", "--quiet", "origin", name
    remote_git "--git-dir", @dotfiles_repo, "symbolic-ref", "HEAD", "refs/heads/#{name}"
    remote_git "-C", @dotfiles_checkout, "push", "--quiet", "origin", "--delete", "main"
    note_situation "The dotfiles remote's default branch is #{name}; no main branch exists."
  end

  def assert_dotfiles_branch(name)
    root = File.join(docker_journal, "volumes", "farmy-shared", "dotfiles")
    branch = remote_git("-C", root, "symbolic-ref", "--short", "HEAD").strip
    assert_equal name, branch, "The shared clone must track the remote's initially selected default branch.#{transcript}"
  end

  def dirty_dotfiles_checkout
    path = File.join(docker_journal, "volumes", "farmy-shared", "dotfiles", ".zshrc")
    assert File.file?(path), "Expected the initial shared clone before preparing its dirty state.#{transcript}"
    File.write(path, "export UNSAVED_DOTFILES_EDIT=keep\n")
    note_situation "The shared dotfiles checkout has an uncommitted .zshrc change that a pull must preserve."
  end

  def rewrite_dotfiles_upstream
    remote_git "-C", @dotfiles_checkout, "checkout", "--quiet", "--orphan", "replacement"
    File.write(File.join(@dotfiles_checkout, ".zshrc"), "export REWRITTEN_DOTFILES=unrelated\n")
    remote_git "-C", @dotfiles_checkout, "add", "--all"
    remote_git "-C", @dotfiles_checkout, "commit", "--quiet", "-m", "A rewritten upstream with unrelated history"
    remote_git "-C", @dotfiles_checkout, "push", "--quiet", "--force", "origin", "HEAD:main"
    note_situation "The dotfiles remote's main branch has unrelated rewritten history; it is not a fast-forward of the applied clone."
  end

  def change_dotfiles_repository
    other = File.join(scratch, "other-dotfiles.git")
    remote_git "clone", "--quiet", "--bare", @dotfiles_repo, other
    config = YAML.safe_load(read_file("farmy.yml"))
    config.fetch("dotfiles")["repo"] = "file://#{other}"
    write_file "farmy.yml", YAML.dump(config)
    note_situation "farmy.yml now names a different dotfiles repository URL; no migration has been authorized."
  end

  def remember_dotfiles_checkout
    @remembered_dotfiles_checkout = dotfiles_checkout_snapshot
  end

  def assert_dotfiles_checkout_unchanged
    assert_equal @remembered_dotfiles_checkout, dotfiles_checkout_snapshot,
      "A refused dotfiles pull must preserve the checkout's HEAD, branch, origin and all user-visible file bytes.#{transcript}"
  end

  def assert_dotfiles_applied_revision(service)
    assert_equal @dotfiles_revision, service_json(service).dig("dotfiles", "revision"),
      "A refused pull must retain #{service}'s last successfully applied dotfiles revision.#{transcript}"
  end

  def app_home_file(service, path, content)
    destination = File.join(docker_journal, "homes", service, path)
    FileUtils.mkdir_p(File.dirname(destination))
    File.write(destination, content)
    note_situation "#{service}'s private home has #{path}: #{content.strip.inspect}."
  end

  def app_home_directory(service, path)
    FileUtils.mkdir_p(File.join(docker_journal, "homes", service, path))
  end

  def assert_home_file(service, path, content: nil)
    actual = File.join(docker_journal, "homes", service, path)
    assert File.file?(actual), "Expected #{service}'s home to contain #{path}, after executing farmy's actual home setup script.#{transcript}"
    assert_equal content, File.read(actual), "Expected #{service}'s home/#{path} content.#{transcript}" if content
  end

  def refute_home_path(service, path)
    refute File.exist?(File.join(docker_journal, "homes", service, path)), "Expected #{service}'s home to have no #{path}.#{transcript}"
  end

  def assert_dotfile_link(service, path, content: nil)
    full = File.join(docker_journal, "homes", service, path)
    assert File.symlink?(full), "Expected #{service}'s ~/#{path} to be a symlink into the one shared dotfiles clone.#{transcript}"
    assert File.exist?(full), "Expected #{service}'s ~/#{path} symlink to have a readable target.#{transcript}"
    assert File.realpath(full).start_with?(File.join(docker_journal, "volumes", "farmy-shared", "dotfiles") + "/"),
      "Expected #{service}'s ~/#{path} to point into farmy-shared/dotfiles, not a second checkout.#{transcript}"
    assert_equal content, File.read(full), "Expected updated content through #{service}'s ~/#{path} link.#{transcript}" if content
  end

  def assert_default_dotfile_links(service)
    %w[.bashrc .zshrc .profile .gitconfig .config/nvim/init.lua].each { |path| assert_dotfile_link service, path }
    %w[.git .github install.sh].each { |path| refute_home_path service, path }
  end

  def assert_dotfile_backups(service, count: 1, originals: {})
    root = File.join(docker_journal, "homes", service, ".dotfiles-backup")
    folders = Dir.glob("*", base: root).select { |path| File.directory?(File.join(root, path)) }
    assert_equal count, folders.length, "Expected one timestamped backup directory on the first apply and no second backup on repeated start.#{transcript}"
    if count > 0
      bytes = { ".bashrc" => "# image skel .bashrc\n", ".zshrc" => "# image skel .zshrc\n", ".profile" => "# image skel .profile\n" }.merge(originals)
      bytes.each do |path, content|
        backup = File.join(root, folders.first, path)
        assert File.file?(backup), "Expected the original #{path} in ~/.dotfiles-backup/<timestamp>/ before replacing it.#{transcript}"
        assert_equal content, File.binread(backup), "The backup must preserve #{path}'s original bytes, not merely create a file with that name.#{transcript}"
      end
    end
  end

  def assert_backup_reported_once
    mentions = (stdout + "\n" + stderr).scan(%r{\.dotfiles-backup/[^\s/]+})
    assert_equal 1, mentions.length, "Expected one backup-directory report for this application, regardless of how many files were replaced.#{transcript}"
  end

  def assert_installer_applied(service, count:)
    path = File.join(docker_journal, "homes", service, ".dotfiles-installations")
    assert File.file?(path), "Expected #{service} to execute the repository's install.sh, producing ~/.dotfiles-installations.#{transcript}"
    lines = File.readlines(path, chomp: true)
    assert_equal count, lines.length, "Expected install.sh to run on each start/pull for #{service}.#{transcript}"
    user, home, cwd, revision = lines.last.split("\t")
    assert_equal "dev", user, "The dotfiles installer must run as dev.#{transcript}"
    assert_equal File.join(docker_journal, "homes", service), home, "The installer must receive the real dev HOME.#{transcript}"
    assert_equal File.join(docker_journal, "volumes", "farmy-shared", "dotfiles"), File.realpath(cwd), "The installer's working directory must be the shared repository root.#{transcript}"
    assert_equal @dotfiles_revision, revision, "Expected #{service}'s installer to apply the current clone revision.#{transcript}"
    calls = docker_state["execs"].select { |entry| entry["container"] == service && entry["command"].join(" ").include?("farmy-home.sh") }
    assert calls.any? { |entry| %w[dev 1001 1001:1001].include?(entry["user"]) }, "Expected farmy-home.sh to be invoked explicitly as dev for #{service}.#{transcript}"
  end

  def assert_shared_dotfiles_clone(count: 1)
    root = File.join(docker_journal, "volumes", "farmy-shared", "dotfiles")
    assert File.directory?(File.join(root, ".git")), "Expected one complete Git checkout at farmy-shared/dotfiles.#{transcript}"
    out, status = Open3.capture2e(Workspace::GIT_ENV, "git", "-C", root, "rev-parse", "HEAD")
    assert status.success? && out.strip == @dotfiles_revision, "Expected the shared clone at the requested remote revision, got #{out.inspect}.#{transcript}"
    clones = docker_state.fetch("toolbox_git_operations", []).count { |entry| entry["operation"] == "clone" && entry["destination"].to_s.include?("dotfiles") }
    assert_equal count, clones, "Expected only #{count} dotfiles clone operation(s) across app starts, got #{clones}.#{transcript}"
  end

  def assert_dotfiles_authentication(transport)
    requests = docker_state.fetch("toolbox_git_requests", [])
    assert requests.any? { |entry| entry["auth"] == transport.to_s && entry["authenticated"] },
      "Expected the private dotfiles clone to authenticate through the #{transport} route and loaded broker; no direct unauthenticated clone may pass.#{transcript}"
    assert_shared_dotfiles_clone
    refute_secret_anywhere "frg_dotfiles_4f928cb" if transport == :token
  end

  def assert_dotfiles_status(service, state:, revision: :current)
    row = service_json(service)["dotfiles"]
    assert row.is_a?(Hash), "Expected status --json service.dotfiles with applied revision and state.#{transcript}"
    assert_equal state, row["state"], "Expected #{service}'s per-container dotfiles apply result.#{transcript}"
    sha = revision == :previous ? @previous_dotfiles_revision : @dotfiles_revision
    assert_equal sha, row["revision"], "Expected #{service}'s recorded revision to be the last successfully applied commit.#{transcript}"
  end

  def assert_dotfiles_readonly(service)
    c = container(service)
    assert c, "Expected running app #{service}.#{transcript}"
    mounted = c["volumes"].select { |mount| mount["name"] == "farmy-shared" }
    assert mounted.any? { |mount| mount["ro"] && (mount["subpath"] == "dotfiles" || mount["target"].end_with?("/dotfiles")) },
      "Expected #{service} to receive farmy-shared/dotfiles as a read-only submount; a read-write shared parent must not offer an alternate writable path.#{transcript}"
  end

  def app_platform(service, architecture:, libc:)
    change_docker_state { |state| (state["app_platforms"] ||= {})[service] = { "architecture" => architecture, "libc" => libc } }
    image = libc == "musl" ? "alpine:3.21" : "debian:bookworm-slim"
    write_file "services/#{service}.yml", "repo: none\nimage: #{image}\n"
  end

  def assert_shared_tool_data(service, other:, platform:)
    %w[.local/share/nvim .cache/nvim].each do |path|
      a, b = [service, other].map { |name| File.join(docker_journal, "homes", name, path) }
      assert File.symlink?(a) && File.symlink?(b), "Expected only the named nvim share/cache directories to link into shared tool data.#{transcript}"
      assert File.exist?(a) && File.exist?(b), "Expected shared nvim links to refer to existing directories.#{transcript}"
      assert_equal File.realpath(a), File.realpath(b), "Expected same platform/libc/selected versions to reuse one #{path} directory.#{transcript}"
      assert_includes File.realpath(a), "/tool-data/#{platform}/", "Expected tool data separated by platform and libc.#{transcript}"
      assert File.writable?(a), "Shared tool data must be writable as dev.#{transcript}"
    end
    refute File.symlink?(File.join(docker_journal, "homes", service, ".local/share")), "Do not share all of ~/.local/share.#{transcript}"
    refute File.symlink?(File.join(docker_journal, "homes", service, ".cache")), "Do not share all of ~/.cache.#{transcript}"
  end

  def assert_distinct_tool_data(*services)
    %w[.local/share/nvim .cache/nvim].each do |relative|
      paths = services.map do |service|
        path = File.join(docker_journal, "homes", service, relative)
        assert File.symlink?(path), "Expected #{service}'s selected #{relative} symlink.#{transcript}"
        assert File.exist?(path), "Expected #{service}'s selected #{relative} link to have an existing target.#{transcript}"
        File.realpath(path)
      end
      assert_equal paths.length, paths.uniq.length, "Different platform/libc/selected tool versions must not share #{relative}.#{transcript}"
    end
  end

  def assert_no_shared_logins(service)
    mounted = container(service).fetch("volumes").select { |mount| mount["name"] == "farmy-shared" }
    assert mounted.all? { |mount| %w[dotfiles tool-data].include?(mount["subpath"].to_s) || mount["subpath"].to_s.start_with?("tool-data/") },
      "shared_logins:false may mount dotfiles/tool-data subpaths only; it must never expose the whole farmy-shared volume or another service's login directories. Got #{mounted.inspect}.#{transcript}"
  end

  def assert_pull_partial(failed:, applied:)
    output = stdout + "\n" + stderr
    assert_match(/partial/i, output, "A pull that applies only some containers must report partial application.#{transcript}")
    assert_match(/#{Regexp.escape(failed)}.*fail|fail.*#{Regexp.escape(failed)}/i, output, "Expected the failed container named.#{transcript}")
    assert_match(/#{Regexp.escape(applied)}.*appl|appl.*#{Regexp.escape(applied)}/i, output, "Expected the successfully applied container named.#{transcript}")
    refute_match(/rolled back|rollback complete/i, output, "A partial pull must make no claim of rollback.#{transcript}")
  end

  def assert_named_shared_data(first, second, name)
    %w[.local/share .cache].each do |parent|
      a, b = [first, second].map { |service| File.join(docker_journal, "homes", service, parent, name) }
      assert File.symlink?(a) && File.symlink?(b), "Expected shared_data:[#{name}] to link #{parent}/#{name} in each app.#{transcript}"
      assert_equal File.realpath(a), File.realpath(b), "Expected both apps to reuse #{parent}/#{name}.#{transcript}"
    end
  end

  def assert_private_data_not_migrated(basename)
    found = Dir.glob(File.join(docker_journal, "volumes", "farmy-shared", "**", basename))
    assert found.empty?, "Existing private home data must not be copied or moved into farmy-shared automatically.#{transcript}"
  end

  def assert_login_shell(service, shell)
    exec = docker_state["execs"].reverse.find { |entry| entry["container"] == service && entry["command"].any? { |word| File.basename(word) == shell } }
    assert exec, "Expected farmy ssh #{service} to launch dev's selected #{shell} login shell.#{transcript}"
    flags = exec["command"].drop(1)
    assert flags.any? { |arg| arg == "--login" || arg.match?(/\A-[a-z]*l[a-z]*\z/) }, "Expected an interactive login #{shell} (-l) from farmy ssh.#{transcript}"
    assert %w[dev 1001 1001:1001].include?(exec["user"]), "farmy ssh must run as dev.#{transcript}"
    build = toolbox_build(service)
    text = [build["dockerfile"], *(build["file_texts"] || {}).values].join("\n")
    assert_match(/(?:chsh|usermod|useradd|adduser)[^\n]*(?:SHELL|shell|zsh)|(?:SHELL|shell)[^\n]*(?:chsh|usermod|useradd|adduser)/, text,
      "The toolbox must set dev's login shell, not just launch zsh manually.#{transcript}")
  end

  def start_apps_concurrently(*services)
    remember_workspace
    before = situation.dup
    threads = services.map do |service|
      Thread.new { [service, *Open3.capture3(Workspace::GIT_ENV.merge(farmy_env), Target.path(PROGRAM), "start", service, chdir: dir)] }
    end
    values = threads.map(&:value)
    @finished = Commands::Finished.new("farmy start #{services.join(' & farmy start ')}", values.map { |name, out, _, _| "#{name}: #{out}" }.join,
      values.map { |name, _, err, _| "#{name}: #{err}" }.join, values.all? { |_, _, _, status| status.success? } ? 0 : 1, before)
  end

  def real_toolbox_workspace
    skip "needs a real Docker daemon; Docker is unavailable or only the fake answers" unless real_docker?
    toolbox_workspace
  end

  def build_and_run_real_toolbox(service, architecture:)
    path = ENV.fetch("PATH").split(":").reject { |entry| entry == Farmy::FAKES }.join(":")
    environment = { "PATH" => path }
    probe, probe_status = Open3.capture2e(environment, "docker", "run", "--rm", "--platform", "linux/#{architecture}",
      "--entrypoint", "/bin/true", "debian:bookworm-slim")
    skip "linux/#{architecture} execution is unavailable: #{probe.lines.last.to_s.strip}" if !probe_status.success? && probe.match?(/exec format error|no matching manifest|cannot execute binary file|qemu.*(?:not found|unsupported)/i)
    assert probe_status.success?, "Could not probe real linux/#{architecture} Docker execution: #{probe}"
    build = toolbox_build(service)
    context = build["context"]
    assert context && File.directory?(context), "Expected the actual toolbox build context to remain available for a real architecture build.#{transcript}"
    tag = "farmy-toolbox-integration-#{Process.pid}:#{architecture}"
    (@real_toolbox_images ||= []) << tag
    arguments = ["docker", "build", "--platform", "linux/#{architecture}", "-t", tag]
    Array(build["args"]).each { |argument| arguments.concat(["--build-arg", argument]) }
    arguments << context
    out, err, status = Timeout.timeout(900) { Open3.capture3(environment, *arguments) }
    @finished = Commands::Finished.new("docker build --platform linux/#{architecture} (farmy generated app image)", out, err, status.exitstatus, [])
    assert_success
    @real_tool_versions, err, status = Open3.capture3(environment, "docker", "run", "--rm", "--platform", "linux/#{architecture}",
      "--entrypoint", "sh", tag, "-c", "uname -m && nvim --version && rg --version && printf 'LANG=%s\n' \"$LANG\" && printf 'charmap=%s\n' \"$(locale charmap)\"")
    @real_tool_entries = YAML.safe_load(toolbox_context(service, "tools.yml"))
    @finished = Commands::Finished.new("docker run --platform linux/#{architecture} app-image: uname -m; nvim --version; rg --version; LANG; locale charmap",
      @real_tool_versions, err, status.exitstatus, [])
  end

  def assert_real_tool_versions(architecture:)
    expected_arch = architecture == "arm64" ? "aarch64" : "x86_64"
    assert_match(/^#{expected_arch}$/, @real_tool_versions, "The binaries must execute on the requested architecture, not just appear in a manifest.#{transcript}")
    assert_includes @real_tool_versions, "NVIM v#{@real_tool_entries.fetch('neovim').fetch('version').delete_prefix('v')}",
      "The real Neovim binary must report the selected catalogue version.#{transcript}"
    assert_includes @real_tool_versions, "ripgrep #{@real_tool_entries.fetch('ripgrep').fetch('version').delete_prefix('v')}",
      "The real ripgrep binary must report the selected catalogue version.#{transcript}"
  end

  def assert_real_utf8_locale
    assert_includes @real_tool_versions, "LANG=C.UTF-8\n", "The real app image must run with LANG=C.UTF-8 from farmy's toolbox layer.#{transcript}"
    assert_includes @real_tool_versions, "charmap=UTF-8\n", "The real app image's C library must accept LANG=C.UTF-8 (locale charmap UTF-8, not ANSI_X3.4-1968).#{transcript}"
  end

  def assert_locked_counter(version:, arm64_musl:)
    lock = YAML.safe_load(read_file("tools.lock"))
    assert_equal 1, lock["version"], "Expected tools.lock schema version 1.#{transcript}"
    assert_equal version, lock.dig("tools", "counter", "version"), "Expected toolbox bump to persist the stable release pin in tools.lock.#{transcript}"
    assert_equal arm64_musl, lock.dig("tools", "counter", "artifacts", "linux-arm64-musl", "sha256"), "Expected bump to verify and persist even the arm64 musl combination, not just the running platform.#{transcript}"
    assert_equal %w[linux-amd64-glibc linux-amd64-musl linux-arm64-glibc linux-arm64-musl], lock.dig("tools", "counter", "artifacts").keys.sort,
      "Expected every required architecture/libc pin in tools.lock.#{transcript}"
    YAML.safe_load(expected("toolbox/counter-2.0.0-pins.yml")).each do |platform, checksum|
      artifact = lock.dig("tools", "counter", "artifacts", platform)
      assert_equal checksum, artifact["sha256"], "Expected counter 2.0.0's exact verified #{platform} SHA-256.#{transcript}"
      assert_equal "/assets/counter-2.0.0-#{platform}", URI(artifact["url"]).path,
        "Expected counter #{platform}'s lock URL to name the newly verified version, not an inherited old artifact.#{transcript}"
    end
  end

  def assert_release_downloads(*platforms)
    platforms.each do |platform|
      assert @tool_release_requests.any? { |request| request.end_with?("counter-2.0.0-#{platform}") }, "Expected bump to download and verify counter 2.0.0 for #{platform}; requests: #{@tool_release_requests.join(', ')}.#{transcript}"
    end
  end

  def after_teardown
    @tool_release_server&.close
    @tool_release_thread&.join(1)
    Array(@real_toolbox_images).each { |tag| real_docker "image", "rm", "-f", tag }
    super
  end

  private

  def dotfiles_checkout_snapshot
    root = File.join(docker_journal, "volumes", "farmy-shared", "dotfiles")
    assert File.directory?(File.join(root, ".git")), "Expected the existing dotfiles checkout to remain present.#{transcript}"
    files = Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject { |path| path == ".git" || path.start_with?(".git/") }
    contents = files.sort.filter_map do |relative|
      full = File.join(root, relative)
      [relative, File.symlink?(full) ? ["link", File.readlink(full)] : ["file", File.binread(full)]] if File.file?(full) || File.symlink?(full)
    end.to_h
    { "head" => remote_git("-C", root, "rev-parse", "HEAD"),
      "branch" => remote_git("-C", root, "symbolic-ref", "HEAD"),
      "origin" => remote_git("-C", root, "remote", "get-url", "origin"), "files" => contents }
  end

  def start_tool_releases
    @tool_release_server = TCPServer.new("127.0.0.1", 0)
    @tool_release_url = "http://127.0.0.1:#{@tool_release_server.addr[1]}"
    @tool_release_requests = []
    @tool_release_thread = Thread.new do
      loop do
        client = @tool_release_server.accept
        request = client.gets.to_s.split[1].to_s
        while (line = client.gets) && line != "\r\n"; end
        @tool_release_requests << request
        status, body = release_response(request)
        client.write "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    @tool_release_thread.report_on_exception = false
  end

  def release_response(request)
    path = request.split("?").first
    if (release_match = path.match(%r{\A/repos/acme/(counter|gauge)/releases}))
      requested_tool = release_match[1]
      assets = COUNTER_PINS.fetch("2.0.0").reject { |platform, _| platform == @tool_release_missing && requested_tool == @tool_release_missing_tool }.map do |platform, checksum|
        name = "counter-2.0.0-#{platform}"
        { "name" => name, "browser_download_url" => "#{@tool_release_url}/assets/#{name}", "digest" => "sha256:#{checksum}" }
      end
      release = { "tag_name" => "v2.0.0", "draft" => false, "prerelease" => false, "assets" => assets }
      return ["200 OK", JSON.generate(path.end_with?("/latest") ? release : [release])]
    end
    if (match = path.match(%r{\A/assets/counter-(1\.0\.0|2\.0\.0)-(linux-(?:amd64|arm64)-(?:glibc|musl))\z}))
      version, platform = match.captures
      body = "#!/bin/sh\nprintf \"counter #{version} #{platform}\\n\"\n"
      body += "# tampered\n" if version == "2.0.0" && platform == @tool_release_corrupt
      return ["200 OK", body]
    end
    ["404 Not Found", "fixture release resource not found"]
  end
end
