module MiniRegressions
  CONTROL_CONTEXT_INPUTS = %w[
    Dockerfile .dockerignore Dockerfile.dockerignore VERSION Cargo.toml Cargo.lock
    crates/control/Cargo.toml crates/control/build.rs crates/control/src/main.rs
    crates/control/resources/defaults.yml farmy README.md .env.example farmy.example.yml
    agents.yml tools.yml egress-hosts.yml factory-prompt.md keys.Dockerfile
    knowledge.Dockerfile gate.Dockerfile docs/guide.md toolbox/entrypoint.sh
    providers/provider.sh
  ].freeze

  def local_control_checkout
    @control_checkout = File.join(scratch, "control-source")
    CONTROL_CONTEXT_INPUTS.each do |path|
      target = File.join(@control_checkout, path)
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, "# Public build fixture: #{path}\n")
    end
    FileUtils.cp(Target.path("farmy"), File.join(@control_checkout, "farmy"))
    File.chmod(0755, File.join(@control_checkout, "farmy"))
    File.write(File.join(@control_checkout, "VERSION"), "0.1.0\n")
    %w[version-a.md version-b.md].each do |path|
      FileUtils.cp(File.join(@control_checkout, "docs/guide.md"), File.join(@control_checkout, "docs", path))
    end
    File.symlink("version-a.md", File.join(@control_checkout, "docs/linked.md"))
    File.write(File.join(@control_checkout, "Dockerfile"), <<~DOCKERFILE)
      FROM alpine:3.21
      COPY VERSION Cargo.toml Cargo.lock farmy README.md .env.example farmy.example.yml agents.yml tools.yml egress-hosts.yml factory-prompt.md keys.Dockerfile knowledge.Dockerfile gate.Dockerfile /distribution/
      COPY crates/ /distribution/crates/
      COPY docs/ /distribution/docs/
      COPY toolbox/ /distribution/toolbox/
      COPY providers/ /distribution/providers/
      CMD ["sleep", "infinity"]
    DOCKERFILE
    note_situation "A local source checkout contains Docker's control build inputs; Docker is faked, so source bytes are opaque and no host compiler is used. FARMY_BUILD and FARMY_REGISTRY are unset."
  end

  def normal_local_init
    plumbing = farmy_env.merge("FARMY_BUILD" => "", "FARMY_REGISTRY" => "", "FARMY_SOURCE" => "")
    saved = plumbing.keys.to_h { |key| [key, ENV[key]] }
    plumbing.each { |key, value| ENV[key] = value }
    execute(File.join(@control_checkout, "farmy"), ["init"], shown_as: "farmy")
  ensure
    saved&.each { |key, value| ENV[key] = value }
  end

  def built_local_control
    local_control_checkout
    normal_local_init
    assert_success
    assert_builds "farmy:local", 1
    @original_control_started = container("farmy").fetch("started_seq")
    @original_control_hash = docker_state.fetch("images").fetch("farmy:local").dig("labels", "farmy.hash")
  end

  def change_control_input(path)
    file = File.join(@control_checkout, path)
    File.open(file, "a") { |stream| stream << (path == "VERSION" ? "\n" : "\n# Changed build input, same release version\n") }
    note_situation "The content of local control input #{path} changed after the first init; VERSION still denotes 0.1.0."
  end

  def mutate_control_input(kind)
    case kind
    when :addition
      File.write(File.join(@control_checkout, "crates/control/src/new_module.rs"), "// Newly included source\n")
    when :deletion
      File.unlink(File.join(@control_checkout, "crates/control/resources/defaults.yml"))
    when :mode
      File.chmod(0755, File.join(@control_checkout, "providers/provider.sh"))
    when :symlink
      target = File.join(@control_checkout, "docs/linked.md")
      File.unlink(target)
      File.symlink("version-b.md", target)
    when :type
      target = File.join(@control_checkout, "docs/guide.md")
      File.unlink(target)
      File.symlink("version-a.md", target)
    end
    note_situation "Control build input mutation: #{kind}; release version is unchanged."
  end

  def assert_control_rebuilt
    assert_builds "farmy:local", 2
    hash = docker_state.fetch("images").fetch("farmy:local").dig("labels", "farmy.hash")
    refute_equal @original_control_hash, hash, "Changed build inputs must produce a different control source hash at the same VERSION.#{transcript}"
    assert_operator container("farmy").fetch("started_seq"), :>, @original_control_started,
      "Normal init must replace the stale running control container after rebuilding changed source.#{transcript}"
  end

  def assert_control_reused
    assert_builds "farmy:local", 1
    assert_equal @original_control_started, container("farmy").fetch("started_seq"),
      "Unchanged local build inputs must retain the running control container.#{transcript}"
  end

  def toolbox_without_version
    farmy "start", "shop"
    assert_success
    change_docker_state do |state|
      state.fetch("images").fetch(state.fetch("containers").fetch("shop").fetch("image")).fetch("labels").delete("farmy.version")
    end
    note_situation "The existing app image predates farmy.version labels; its labels contain no farmy.version key."
  end

  def personal_git_dotfiles(transport = :token)
    dotfiles_workspace
    settings name: "Container Default", email: "dev@example.com"
    @personal_gitconfig = fixture("dotfiles/git-personal.txt")
    File.write(File.join(@dotfiles_checkout, ".gitconfig"), @personal_gitconfig)
    remote_git "-C", @dotfiles_checkout, "add", ".gitconfig"
    remote_git "-C", @dotfiles_checkout, "commit", "--quiet", "-m", "Personal Git preferences"
    remote_git "-C", @dotfiles_checkout, "push", "--quiet", "origin", "main"
    @dotfiles_revision = remote_git("-C", @dotfiles_checkout, "rev-parse", "HEAD").strip
    private_dotfiles transport
    config = YAML.safe_load(read_file("farmy.yml"))
    config["egress"] = { "proxy" => "http://proxy.example.com:8080" }
    write_file "farmy.yml", YAML.dump(config)
    farmy "start", "shop"
    assert_success
    assert_dotfile_link "shop", ".gitconfig", content: @personal_gitconfig
    if transport == :ssh
      app = container("shop")
      socket_path = app.fetch("env").fetch("SSH_AUTH_SOCK")
      mount = app.fetch("volumes").select { |entry| socket_path.start_with?(entry["target"] + "/") }.max_by { |entry| entry["target"].length }
      raise "The app's SSH_AUTH_SOCK must come from a broker volume" unless mount
      local_socket = File.join(docker_journal, "volumes", mount.fetch("name"), mount["subpath"].to_s, socket_path.delete_prefix(mount.fetch("target") + "/"))
      FileUtils.mkdir_p(File.dirname(local_socket))
      FileUtils.rm_f(local_socket)
      (@entrypoint_sockets ||= []) << UNIXServer.new(local_socket)
    end
    change_docker_state { |state| state["entrypoint_runtime"] = true }
    note_situation "The app has a read-only dotfiles-linked ~/.gitconfig with a personal identity, editor and conflicting HTTPS/SSH transport preferences. The actual emitted entrypoint runs against real Git; only OS ownership and daemon startup are simulated."
  end

  def run_app_entrypoint
    entrypoint = toolbox_build("shop")["entrypoint"]
    refute_empty Array(entrypoint), "Expected the emitted toolbox image to identify its executable entrypoint.#{transcript}"
    execute(File.join(Farmy::FAKES, "docker"), ["exec", "-u", "root", "shop", *entrypoint],
      shown_as: "docker", env: farmy_env.compact)
    assert_stdout " ready."
  end

  def git_in_app(*arguments)
    farmy "run", "shop", "git", *arguments
  end

  def assert_personal_gitconfig_preserved
    assert_dotfile_link "shop", ".gitconfig", content: @personal_gitconfig
  end

  def git_route_probe(url)
    farmy "run", "shop", "sh", "-c", "git init -q /workspace/route-probe && git -C /workspace/route-probe remote add origin #{Shellwords.escape(url)} && git -C /workspace/route-probe remote get-url origin"
  end

  def after_teardown
    @entrypoint_sockets&.each(&:close)
    super
  end
end
