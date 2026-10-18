# Worker-owned integration check: Git authentication survives isolated public metadata creation.
# The SSH transport is local and cannot contact a network host.
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'yaml'
require 'shellwords'

class PublishingTransportCheck < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def test_configured_ssh_transport_is_used_without_exporting_ambient_identity
    Dir.mktmpdir('farmy-publishing-transport-') do |tmp|
      source = File.join(tmp, 'source')
      remote = File.join(tmp, 'public.git')
      host_bin = File.join(tmp, 'host-bin')
      log = File.join(tmp, 'transport.log')
      personal = File.join(tmp, 'personal.gitconfig')
      transport = File.join(tmp, 'authenticated-ssh')
      denylist = File.join(tmp, 'denylist')
      FileUtils.mkdir_p([source, host_bin])
      File.write(denylist, "source-only@example.com\n")
      File.write(File.join(host_bin, 'ssh'), "#!/bin/sh\necho 'network transport disabled by worker check' >&2\nexit 97\n")
      File.chmod(0755, File.join(host_bin, 'ssh'))
      File.write(transport, <<~'SH')
        #!/bin/sh
        set -eu
        printf 'authenticated transport\n' >> "$CHECK_TRANSPORT_LOG"
        for argument do command=$argument; done
        case "$command" in
          "git-upload-pack "*|"git-receive-pack "*) exec sh -c "$command" ;;
          *) exit 97 ;;
        esac
      SH
      File.chmod(0755, transport)
      env = {
        'PATH' => "#{host_bin}:#{ENV.fetch('PATH')}", 'GIT_CONFIG_NOSYSTEM' => '1',
        'GIT_CONFIG_GLOBAL' => personal, 'GIT_CONFIG_COUNT' => '0',
        'GIT_SSH' => nil, 'GIT_SSH_COMMAND' => nil, 'GIT_SSH_VARIANT' => 'ssh',
        'CHECK_TRANSPORT_LOG' => log, 'PRIVATE_TERMS_FILE' => denylist,
        'GIT_AUTHOR_NAME' => 'Source Developer', 'GIT_AUTHOR_EMAIL' => 'source-only@example.com',
        'GIT_COMMITTER_NAME' => 'Source Developer', 'GIT_COMMITTER_EMAIL' => 'source-only@example.com'
      }
      command = lambda do |*args, cwd: source|
        out, err, status = Open3.capture3(env, *args, chdir: cwd)
        assert status.success?, "#{args.inspect}\n#{out}\n#{err}"
        out
      end
      command.call('git', 'config', '--file', personal, 'core.sshCommand', Shellwords.escape(transport))
      command.call('git', 'init', '-q', '--initial-branch=main')
      command.call('git', 'init', '-q', '--bare', remote)
      version = File.read(File.join(ROOT, 'work/VERSION')).strip
      config = YAML.safe_load(File.read(File.join(ROOT, 'work/release.yml')))
      config['public_remote'] = 'public'
      FileUtils.mkdir_p([File.join(source, 'work/releases'), File.join(source, 'bin')])
      File.write(File.join(source, 'README.md'), "# Public source\n")
      File.write(File.join(source, 'work/VERSION'), "#{version}\n")
      File.write(File.join(source, 'work/release.yml'), YAML.dump(config))
      File.write(File.join(source, "work/releases/#{version}.md"), "# Release #{version}\n\nContributor credits are maintained explicitly.\n")
      File.write(File.join(source, 'work/public-files.txt'), "README.md\nwork/VERSION\nwork/release.yml\nwork/public-files.txt\nwork/releases/\nbin/scan-private\nbin/scan-history\n")
      %w[scan-private scan-history].each { |name| FileUtils.cp(File.join(ROOT, 'bin', name), File.join(source, 'bin', name), preserve: true) }
      command.call('git', 'add', '.')
      command.call('git', 'commit', '-qm', 'Private source input')
      private_commit = command.call('git', 'rev-parse', 'HEAD').strip
      command.call('git', 'remote', 'add', 'public', "ssh://git@example.com#{remote}")
      output = command.call(File.join(ROOT, 'bin/publish'), version)
      assert_includes output, 'Published'
      assert_includes File.read(log), 'authenticated transport'
      public_identity = "#{config.fetch('maintainer_name')} <#{config.fetch('maintainer_email')}>"
      identities = command.call('git', '--git-dir', remote, 'log', '-1', '--format=%an <%ae>%n%cn <%ce>', 'main').lines.map(&:strip)
      assert_equal [public_identity, public_identity], identities
      _, _, private_found = Open3.capture3(env, 'git', '--git-dir', remote, 'cat-file', '-e', private_commit)
      refute private_found.success?, 'private development commit must not enter public object storage'
    end
  end
end

class PublishingPrivacyEncodingCheck < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def test_both_scanners_find_case_insensitive_utf8_terms_inside_binary_bytes
    Dir.mktmpdir('farmy-privacy-encoding-') do |tmp|
      tree = File.join(tmp, 'public')
      FileUtils.mkdir_p(tree)
      list = File.join(tmp, 'denylist')
      File.write(list, "private café\n")
      File.binwrite(File.join(tree, 'asset.bin'), "\0PRIVATE CAFÉ\0".b)
      env = { 'PRIVATE_TERMS_FILE' => list, 'FARMY_SCAN_REQUIRED' => '1',
        'GIT_CONFIG_GLOBAL' => File::NULL, 'GIT_CONFIG_NOSYSTEM' => '1',
        'GIT_AUTHOR_NAME' => 'farmy maintainers', 'GIT_AUTHOR_EMAIL' => 'maintainers@example.com',
        'GIT_COMMITTER_NAME' => 'farmy maintainers', 'GIT_COMMITTER_EMAIL' => 'maintainers@example.com' }
      [['init', '-q'], ['add', '.'], ['commit', '-qm', 'Public candidate']].each do |args|
        _, err, status = Open3.capture3(env, 'git', *args, chdir: tree)
        assert status.success?, err
      end
      %w[scan-private scan-history].each do |scanner|
        out, err, status = Open3.capture3(env, File.join(ROOT, 'bin', scanner), chdir: tree)
        refute status.success?, "#{scanner} missed the UTF-8 term in binary content: #{out}\n#{err}"
      end
    end
  end
end
