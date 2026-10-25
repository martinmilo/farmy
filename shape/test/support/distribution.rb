require "rbconfig"

module Distribution
  REGISTRY = "registry.example.com/acme"
  RELEASE_HASH = "1234567890abcdef1234567890abcdef12345678"
  # The version this checkout ships (work/VERSION), set by the owner for each release.
  SHIPPED = "0.2.0"

  def published_release(version = SHIPPED, latest: true, format: 1, registry: REGISTRY)
    artifact = version == SHIPPED ? work_file("farmy") : "#!/bin/sh\ncase \"$1\" in --version) echo 'farmy #{version} (#{RELEASE_HASH})';; *) echo 'release #{version}';; esac\n"
    change_docker_state do |state|
      remote = state["registry"] ||= {}
      %w[control keys knowledge gate].each do |role|
        data = { "labels" => { "farmy.version" => version, "farmy.hash" => RELEASE_HASH, "farmy.format" => format.to_s }, "entrypoint" => [], "cmd" => ["sleep", "infinity"],
                 "artifacts" => { "/usr/local/lib/farmy/farmy" => artifact } }
        remote["#{registry}/farmy-#{role}:#{version}"] = data
        remote["#{registry}/farmy-#{role}:latest"] = data if latest
      end
    end
    note_situation "The registry publishes #{registry}/farmy-{control,keys,knowledge,gate}:#{version}#{latest ? ' and latest' : ''}, format #{format}."
  end

  def distribution_shim(*args, env: {})
    distribution_execute(@installed_shim || Target.path("farmy"), *args, env: env)
  end

  def distribution_farmy(*args)
    farmy(*args, env: { "FARMY_REGISTRY" => REGISTRY, "FARMY_BUILD" => "" })
  end

  def distribution_execute(path, *args, env: {})
    plumbing = farmy_env.merge("FARMY_BUILD" => "", "FARMY_REGISTRY" => REGISTRY, "FARMY_SOURCE" => "")
    plumbing["PATH"] = @host_path if @host_path
    saved = plumbing.keys.to_h { |key| [key, ENV[key]] }
    plumbing.each { |key, value| ENV[key] = value }
    execute(path, args, shown_as: File.basename(path), env: env)
  ensure
    saved&.each { |key, value| ENV[key] = value }
  end

  def standalone_host
    @host_bin = File.join(scratch, "host-bin")
    FileUtils.mkdir_p(@host_bin)
    tools = %w[sh env cat sed awk dirname basename chmod mkdir mktemp cp mv rm readlink realpath pwd head tail tr cut find sort uname wc date id stat ln sleep printf tar touch grep expr test tee cksum cmp dd od xargs uniq getconf expand fold join paste split unexpand]
    tools.each do |name|
      path = ENV.fetch("PATH").split(":").map { |p| File.join(p, name) }.find { |p| File.executable?(p) }
      File.symlink(path, File.join(@host_bin, name)) if path
    end
    File.write(File.join(@host_bin, "docker"), "#!/bin/sh\nexec #{Shellwords.escape(RbConfig.ruby)} #{Shellwords.escape(File.join(Farmy::FAKES, 'docker'))} \"$@\"\n")
    File.chmod(0755, File.join(@host_bin, "docker"))
    @host_path = @host_bin
    @install_dir = File.join(scratch, "installed-bin")
  end

  # The installer as a GitHub release attaches it: work/bin/render-release renders the release's files.
  def install_from_release(to: nil, with_folder_on_path: false)
    standalone_host unless @host_path
    dist = File.join(scratch, "release-dist")
    unless File.exist?(File.join(dist, "install"))
      out, status = Open3.capture2e(RbConfig.ruby, Target.path("bin/render-release"), dist, chdir: Target.root)
      assert status.success?, "Expected work/bin/render-release <folder> to render the release's files (as the release workflow does); it failed:\n#{out}"
    end
    env = with_folder_on_path ? { "PATH" => "#{@install_dir}:#{@host_path}" } : {}
    note_situation "The installer is the release's rendered install; #{with_folder_on_path ? "the install folder is on PATH" : "the install folder is not on PATH"}."
    distribution_execute("/bin/sh", File.join(dist, "install"), "--dir", @install_dir, *(to ? ["--to", to] : []), env: env)
    @installed_shim = File.join(@install_dir, "farmy")
  end

  def install_folder = @install_dir

  def install_distribution(version: nil, env: {})
    standalone_host unless @host_path
    installer = Target.path("bin/install")
    assert File.file?(installer), "Expected the standalone POSIX install script at bin/install."
    distribution_execute("/bin/sh", installer, "--dir", @install_dir, *(version ? ["--to", version] : []), env: env)
    @installed_shim = File.join(@install_dir, "farmy")
  end

  def installed_distribution
    published_release
    install_distribution version: SHIPPED
    assert_success
    assert_installed_only_shim
  end

  def assert_installed_only_shim
    assert File.directory?(@install_dir), "Expected installer to create the requested bin directory.#{transcript}"
    assert_equal ["farmy"], Dir.children(@install_dir), "Expected exactly the standalone shim in the installation directory.#{transcript}"
    assert File.executable?(@installed_shim), "Expected installed farmy to be executable.#{transcript}"
    assert File.read(@installed_shim).start_with?("#!/bin/sh\n"), "Expected a POSIX sh shim, not a host-language program.#{transcript}"
  end

  def remember_installed_shim
    @old_shim = File.binread(@installed_shim)
  end

  def assert_installed_shim_unchanged
    assert_equal @old_shim, File.binread(@installed_shim), "Expected failed update to preserve the usable installed shim.#{transcript}"
  end

  def fail_pull(role, version, registry: REGISTRY)
    change_docker_state { |s| (s["pull_failures"] ||= []) << "#{registry}/farmy-#{role}:#{version}" }
  end

  def missing_shim_artifact(version)
    change_docker_state { |s| s["registry"].fetch("#{REGISTRY}/farmy-control:#{version}")["artifacts"] = {} }
  end

  def assert_pulled(*refs)
    refs.each { |ref| assert_includes Array(docker_state["pulls"]), ref, "Expected Docker to pull #{ref}.#{transcript}" }
  end

  def assert_release_pulled(version)
    %w[control keys knowledge gate].each { |role| assert_pulled "#{REGISTRY}/farmy-#{role}:#{version}" }
  end

  def refute_control_pull
    assert_empty Array(docker_state["pulls"]).grep(/farmy-control:/), "Expected no control pull for an explicit local build.#{transcript}"
  end

  def refute_control_build
    built = docker_state["images"].select { |name, data| (name.include?("farmy-control") || name == "farmy:local") && data["context"] }
    assert_empty built.keys, "Expected a published control pull without a local build.#{transcript}"
  end

  def assert_local_control_built(source: nil)
    built = docker_state["images"].select { |name, data| (name.include?("farmy-control") || name == "farmy:local") && data["context"] }
    refute_empty built, "Expected local fallback to build a control image.#{transcript}"
    assert built.values.any? { |i| i["source"] == source }, "Expected Docker to consume FARMY_SOURCE #{source.inspect}.#{transcript}" if source
  end

  def assert_image_release_labels(version = SHIPPED)
    built = docker_state["images"].select { |_, data| data["context"] }
    refute_empty built, "Expected at least one farmy image build.#{transcript}"
    built.each do |name, data|
      assert_equal version, data.dig("labels", "farmy.version"), "Expected farmy.version=#{version} on built image #{name}.#{transcript}"
      assert_match(/\A[0-9a-f]{8,}\z/, data.dig("labels", "farmy.hash").to_s, "Expected build hash label on #{name}.#{transcript}")
    end
  end

  def toolbox_built_by(version)
    farmy "start", "shop"
    assert_success
    change_docker_state { |s| s["images"].fetch(s["containers"].fetch("shop").fetch("image"))["labels"]["farmy.version"] = version }
  end

  def assert_toolbox_metadata(version, outdated:)
    row = service_json("shop")
    if version.nil?
      assert_nil row["toolbox_version"], "Expected unknown toolbox version as null, without inventing an image version.#{transcript}"
    else
      assert_equal version, row["toolbox_version"], "Expected toolbox version from its image label.#{transcript}"
    end
    assert_equal outdated, row["toolbox_outdated"], "Expected toolbox_outdated=#{outdated}.#{transcript}"
  end

  def newer_running_control
    shim "init"
    assert_success
    change_docker_state { |s| s["images"].fetch(s["containers"].fetch("farmy").fetch("image"))["labels"]["farmy.version"] = "0.3.0" }
  end

  def formatted_file(kind, format)
    if kind == "farmy.yml"
      write_file kind, "format: #{format}\nagents: []\n"
    else
      write_file kind, "format: #{format}\nrepo: none\nimage: debian:bookworm-slim\n"
    end
  end

  def release_distribution(version = SHIPPED, registry: REGISTRY)
    distribution_execute(Target.path("bin/release"), version, env: { "FARMY_REGISTRY" => registry })
  end

  def assert_release_builds(version, registry: REGISTRY)
    calls = Array(docker_state["buildx"])
    %w[control keys knowledge gate].each do |role|
      tag = "#{registry}/farmy-#{role}:#{version}"
      call = calls.find { |c| c["tags"].include?(tag) }
      assert call, "Expected buildx to publish #{tag}.#{transcript}"
      assert_equal %w[linux/amd64 linux/arm64], call["platforms"].sort, "Expected both release architectures for #{tag}.#{transcript}"
      assert call["push"], "Expected --push for #{tag}.#{transcript}"
      assert docker_state["images"].key?("#{registry}/farmy-#{role}:latest"), "Expected a latest release tag for #{role}.#{transcript}"
      labels = docker_state["images"].fetch(tag)["labels"]
      assert_equal version, labels["farmy.version"], "Expected release version label on #{tag}.#{transcript}"
      assert_match(/\A[0-9a-f]{8,}\z/, labels["farmy.hash"].to_s, "Expected release hash label on #{tag}.#{transcript}")
    end
  end

  def refute_release_builds
    assert_empty Array(docker_state["buildx"]), "Expected refusal before a build/push.#{transcript}"
  end

  def buildx_fails
    change_docker_state { |s| s["buildx_failure"] = true }
  end

  def export_gate_image(role: "gate")
    distribution_execute(Target.path("bin/release"), SHIPPED, "--image", role, "--output", File.join(scratch, "gate.oci.tar"), env: { "FARMY_REGISTRY" => "" })
  end

  def assert_gate_export
    calls = Array(docker_state["buildx"])
    assert_equal 1, calls.length, "Expected just the selected gate image built.#{transcript}"
    assert_equal %w[linux/amd64 linux/arm64], calls.first["platforms"].sort
    refute calls.first["push"], "Expected no publication during an OCI export.#{transcript}"
    assert calls.first["outputs"].any? { |o| o.include?("type=oci") && o.include?("gate.oci.tar") }, "Expected an OCI archive destination.#{transcript}"
  end

  def real_multi_platform_build
    require_real_docker "a real Docker with buildx"
    out, status = Open3.capture2e("docker", "buildx", "inspect", "--bootstrap")
    skip "needs a buildx builder supporting amd64 and arm64" unless status.success? && out.include?("linux/amd64") && out.include?("linux/arm64")
    archive = File.join(scratch, "release.oci.tar")
    out, status = Open3.capture2e(Target.path("bin/release"), SHIPPED, "--image", "gate", "--output", archive, chdir: dir)
    assert status.success?, "Expected the real farmy gate multi-platform OCI build to succeed: #{out}"
    assert File.size?(archive), "Expected an OCI archive containing both platforms."
    extracted = File.join(scratch, "oci")
    FileUtils.mkdir_p(extracted)
    out, status = Open3.capture2e("tar", "-xf", archive, "-C", extracted)
    assert status.success?, "Expected a readable OCI archive: #{out}"
    platforms = Dir.glob(File.join(extracted, "**", "*")).select { |p| File.file?(p) }.flat_map do |path|
      next [] if File.size(path) > 1_000_000
      data = JSON.parse(File.read(path)) rescue nil
      next [] unless data.is_a?(Hash)
      Array(data["manifests"]).filter_map { |m| p = m["platform"]; "#{p['os']}/#{p['architecture']}" if p }
    end
    assert_includes platforms, "linux/amd64", "Expected amd64 in the exported OCI descriptors."
    assert_includes platforms, "linux/arm64", "Expected arm64 in the exported OCI descriptors."
  end
end
