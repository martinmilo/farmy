# Worker-owned checks for the standalone host flow. No real Docker calls.
require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'digest'
require 'yaml'
require 'rbconfig'

class StandaloneDistributionCheck < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  VERSION = File.read(File.join(ROOT, 'VERSION')).strip

  def setup
    FileUtils.mkdir_p(File.join(ROOT, 'target', 'worker-checks'))
    @tmp = Dir.mktmpdir('distribution-', File.join(ROOT, 'target', 'worker-checks'))
    @host = File.join(@tmp, 'host-bin')
    @folder = File.join(@tmp, 'containers')
    @install = File.join(@tmp, 'installed')
    @log = File.join(@tmp, 'docker.log')
    FileUtils.mkdir_p([@host, @folder])
    %w[awk basename cat chmod cp cut dirname grep mkdir mktemp mv rm sed sh sort uname].each do |name|
      path = ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }.find { |p| File.executable?(p) }
      raise "missing POSIX utility #{name}" unless path
      File.symlink(path, File.join(@host, name))
    end
    File.write(File.join(@host, 'docker'), <<~'SH')
      #!/bin/sh
      set -eu
      printf '%s\n' "$*" >> "$CHECK_DOCKER_LOG"
      case "$1" in
        info) exit 0 ;;
        pull)
          case "$2" in *"${CHECK_FAIL_PULL:-never-match}"*) exit 1 ;; esac
          exit 0 ;;
        image)
          case "$*" in
            *farmy.version*) printf '%s\n' "${CHECK_RELEASE:-0.2.0}" ;;
            *farmy.format*) printf '%s\n' "${CHECK_FORMAT:-1}" ;;
            *) exit 1 ;;
          esac ;;
        create) printf '%s\n' extract-1 ;;
        cp)
          [ "${CHECK_FAIL_EXTRACT:-0}" != 1 ] || exit 1
          cp "$CHECK_ARTIFACT" "$3" ;;
        rm) [ "$3" = extract-1 ] ;;
        build) exit 1 ;; # Capture the fallback context without running or building any container.
        *) echo "unexpected Docker operation: $*" >&2; exit 1 ;;
      esac
    SH
    File.chmod(0755, File.join(@host, 'docker'))
    @env = {
      'PATH' => @host, 'HOME' => @tmp, 'FARMY_BUILD' => nil,
      'FARMY_REGISTRY' => 'registry.example.com/acme', 'FARMY_SOURCE' => nil,
      'CHECK_DOCKER_LOG' => @log, 'CHECK_ARTIFACT' => File.join(ROOT, 'farmy')
    }
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def run_host(*args, env: {})
    Open3.capture3(@env.merge(env), *args, chdir: @folder)
  end

  def install(env: {})
    out, err, status = run_host(File.join(ROOT, 'bin', 'install'), '--to', VERSION, '--dir', @install, env: env)
    assert status.success?, "#{out}\n#{err}"
    @shim = File.join(@install, 'farmy')
    assert_equal ['farmy'], Dir.children(@install)
  end

  def test_updates_roll_back_after_partial_pull_or_extraction_failure
    install
    original = File.binread(@shim)
    [{ 'CHECK_FAIL_PULL' => 'farmy-knowledge:' }, { 'CHECK_FAIL_EXTRACT' => '1' }].each do |failure|
      File.write(@log, '')
      out, err, status = run_host(@shim, 'update', '--to', '0.2.0', env: failure)
      refute status.success?, "#{out}\n#{err}"
      assert_equal original, File.binread(@shim)
      assert_equal ['farmy'], Dir.children(@install)
      refute File.read(@log).lines.any? { |line| line.match?(/\A(?:stop|restart|run|rm -f farmy)\b/) }
    end
  end

  def test_update_uses_saved_registry_and_preserves_literal_source_defaults
    marker = File.join(@tmp, 'must-not-exist')
    source = "https://git.example.com/farmy.git#release' ; touch #{marker} ; #"
    install(env: { 'FARMY_SOURCE' => source })
    File.write(File.join(@folder, 'farmy.yml'), "farmy: '#{VERSION}' # exact\n")
    before = File.binread(File.join(@folder, 'farmy.yml'))
    File.write(@log, '')
    out, err, status = run_host(@shim, 'update', '--to', '0.2.0', env: { 'FARMY_REGISTRY' => '', 'FARMY_SOURCE' => '' })
    assert status.success?, "#{out}\n#{err}"
    assert_equal before, File.binread(File.join(@folder, 'farmy.yml'))
    %w[control keys knowledge gate].each { |role| assert_includes File.read(@log), "pull registry.example.com/acme/farmy-#{role}:0.2.0" }
    output, errors, result = run_host(@shim, '--version')
    assert result.success?, errors
    assert_includes output, 'farmy 0.2.0'
    refute File.exist?(marker), 'saved values must remain shell literals'
    assert_includes File.read(@shim), 'touch '
  end

  def test_ambiguous_pins_and_multiline_versions_refuse_before_docker_changes
    install
    ["farmy: [#{VERSION}]", "farmy: ^#{VERSION}", "farmy: 01.0.0", "farmy: '#{VERSION}' trailing", "farmy: #{VERSION}\nfarmy: 0.2.0", "{farmy: #{VERSION}}"].each do |pin|
      File.write(File.join(@folder, 'farmy.yml'), pin)
      File.write(@log, '')
      _, err, status = run_host(@shim, 'status')
      refute status.success?, pin
      assert_includes err, 'farmy'
      assert_empty File.read(@log), pin
    end
    FileUtils.rm_f(File.join(@folder, 'farmy.yml'))
    File.write(@log, '')
    _, err, status = run_host(@shim, 'update', '--to', "0.2.0\n0.3.0")
    refute status.success?
    assert_includes err, 'exact MAJOR.MINOR.PATCH'
    refute File.read(@log).include?('pull ')
  end

  def test_future_format_with_future_keys_gives_a_reader_refusal
    install
    File.write(File.join(@folder, 'farmy.yml'), "format: '2' # future\nfarmy: '#{VERSION}'\nfuture_feature: {unfamiliar: true}\n")
    File.write(@log, '')
    _, err, status = run_host(@shim, 'status', env: { 'CHECK_FORMAT' => '2' })
    refute status.success?
    assert_includes err, 'farmy.yml: format 2'
    assert_includes err, 'farmy update --to 0.2.0'
    refute File.read(@log).lines.any? { |line| line.match?(/\A(?:create|rm|run|build) /) }
  end

  def assert_source_after_update(source, expected)
    install(env: { 'FARMY_SOURCE' => source })
    out, err, status = run_host(@shim, 'update', '--to', '0.2.0', env: { 'FARMY_SOURCE' => nil })
    assert status.success?, "#{out}\n#{err}"
    File.write(@log, '')
    run_host(@shim, 'init', env: { 'FARMY_SOURCE' => nil, 'CHECK_FAIL_PULL' => 'farmy-control:' })
    builds = File.read(@log).lines.select { |line| line.start_with?('build ') }
    assert_equal 1, builds.length
    assert_equal expected, builds.first.split.last
  end

  def test_generated_mirror_fallback_advances_to_the_installed_tag
    github = YAML.safe_load(File.read(File.join(ROOT, 'release.yml'))).fetch('github_url')
    assert_source_after_update(nil, "#{github}.git#v0.2.0:work")
  end

  def test_explicit_source_override_remains_pinned_after_update
    source = 'https://github.com/acme/custom-farmy.git#v0.1.0:work'
    assert_source_after_update(source, source)
  end

  def test_explicit_source_equal_to_the_original_default_still_remains_pinned
    github = YAML.safe_load(File.read(File.join(ROOT, 'release.yml'))).fetch('github_url')
    source = "#{github}.git#v#{VERSION}:work"
    assert_source_after_update(source, source)
  end

  def test_rendered_release_installer_is_standalone_and_its_checksum_covers_exact_bytes
    assets = File.join(@tmp, 'assets')
    out, err, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, 'bin/render-release'), assets)
    assert status.success?, "#{out}\n#{err}"
    assert_equal "#{Digest::SHA256.file(File.join(assets, 'install')).hexdigest}  install\n", File.read(File.join(assets, 'SHA256SUMS'))
    out, err, status = run_host(File.join(assets, 'install'), '--to', VERSION, '--dir', @install,
      env: { 'FARMY_REGISTRY' => nil, 'CHECK_ARTIFACT' => File.join(assets, 'farmy') })
    assert status.success?, "#{out}\n#{err}"
    owner = YAML.safe_load(File.read(File.join(ROOT, 'release.yml'))).fetch('owner')
    assert_includes File.read(@log), "pull ghcr.io/#{owner}/farmy/farmy-control:#{VERSION}"
    assert_equal ['farmy'], Dir.children(@install)
  end
end
