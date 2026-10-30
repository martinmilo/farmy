class BuildFromRepositoryTest < AcceptanceTest
  def setup = workspace("workshop") # the toolkit definition is rewritten per test: dockerfile: Dockerfile, target: base, build_files: [Gemfile, Gemfile.lock], repo: on the test's git host

  DOCKERFILE = "FROM ruby:3.4 AS base\nWORKDIR /app\nCOPY Gemfile Gemfile.lock ./\nRUN bundle install\n\nFROM base AS release\nCOPY . .\n".freeze
  GEMFILE = "source 'https://rubygems.org'\ngem 'thor'\n".freeze
  LOCKFILE = "GEM\n  remote: https://rubygems.org/\n  specs:\n    thor (1.3.2)\n".freeze

  test "a service with a dockerfile has the named stage built with the files it copies" do
    remote_repository "acme/toolkit", "Dockerfile" => DOCKERFILE, "Gemfile" => GEMFILE, "Gemfile.lock" => LOCKFILE
    define_from_remote "toolkit", "acme/toolkit"

    farmy "start", "toolkit"

    assert_success
    assert_built target: "base", files: %w[Dockerfile Gemfile Gemfile.lock]
    assert_running "toolkit"
  end

  test "the git container that fetches the build files into the state folder runs as the user farmy runs as, so the files are that user's" do
    remote_repository "acme/toolkit", "Dockerfile" => DOCKERFILE, "Gemfile" => GEMFILE, "Gemfile.lock" => LOCKFILE
    define_from_remote "toolkit", "acme/toolkit"

    farmy "start", "toolkit" # farmy runs as the test's user here, as the shim runs it as the invoking user on Linux

    assert_success
    assert_build_files_fetched_as invoking_user
  end

  test "the Dockerfile is read from the branch the definition names" do
    remote_repository "acme/toolkit", "Dockerfile" => DOCKERFILE, "Gemfile" => GEMFILE, "Gemfile.lock" => LOCKFILE
    remote_repository "acme/toolkit", "Dockerfile" => DOCKERFILE.sub("ruby:3.4", "ruby:3.4-slim"), on: "slim-image"
    define_from_remote "toolkit", "acme/toolkit", branch: "slim-image"

    farmy "start", "toolkit"

    assert_built dockerfile_includes: "FROM ruby:3.4-slim AS base"
  end

  test "a repository that cannot be reached stops the start and names its clone URL" do
    write_file "services/toolkit.yml", "repo: file:///srv/host-that-is-gone/acme/toolkit.git\ndockerfile: Dockerfile\ntarget: base\n"

    farmy "start", "toolkit"

    assert_exit 1
    assert_stderr "file:///srv/host-that-is-gone/acme/toolkit.git"
    refute_container "toolkit"
  end

  test "a build file that is not in the repository stops the start and names it" do
    remote_repository "acme/toolkit", "Dockerfile" => DOCKERFILE, "Gemfile" => GEMFILE
    define_from_remote "toolkit", "acme/toolkit"

    farmy "start", "toolkit"

    assert_exit 1
    assert_stderr "Gemfile.lock"
    refute_container "toolkit"
  end

  test "rebuild builds the image again from the Dockerfile as it is now" do
    remote_repository "acme/toolkit", "Dockerfile" => DOCKERFILE, "Gemfile" => GEMFILE, "Gemfile.lock" => LOCKFILE
    define_from_remote "toolkit", "acme/toolkit"
    farmy "start", "toolkit"
    remote_repository "acme/toolkit", "Dockerfile" => DOCKERFILE.sub("ruby:3.4", "ruby:3.4-slim")

    farmy "rebuild", "toolkit"

    assert_success
    assert_built dockerfile_includes: "FROM ruby:3.4-slim AS base"
  end

  test "with egress the Dockerfile fetch goes through the proxy" do
    proxy = fake_proxy status: 502
    write_file "farmy.yml", "secrets:\n  unlock: [TS_AUTHKEY]\negress:\n  authkey: TS_AUTHKEY\n"
    write_file "services/toolkit.yml", "repo: http://git.example.com/acme/toolkit.git\ndockerfile: Dockerfile\n"

    farmy "start", "toolkit", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n", env: { "FARMY_EGRESS_PROXY" => proxy.url.delete_prefix("http://") }

    assert_includes proxy.targets, "http://git.example.com:80/acme/toolkit.git/info/refs"
  end

  # ── links and paths: the security fix of record 2026-10-29-1800 ──

  test "a build file that is a link to another file in the repository is built with that file's content" do
    remote_repository "acme/toolkit", "Dockerfile" => DOCKERFILE, "Gemfile" => GEMFILE, "locks/Gemfile.lock" => LOCKFILE
    remote_repository_link "acme/toolkit", "Gemfile.lock" => "locks/Gemfile.lock"
    define_from_remote "toolkit", "acme/toolkit"

    farmy "start", "toolkit"

    assert_success
    assert_built target: "base", file_content: ["Gemfile.lock", LOCKFILE]
  end

  { "../.env" => "one folder up", "../../../../.env" => "four folders up, where the clone reaches the containers folder's .env" }.each do |target, where|
    test "a build file that is a link #{where} (#{target}), out of the repository, stops the start, naming it, and nothing of the containers folder's .env reaches a build context or the output" do
      the_folder_env_also_holds "DEPLOY_TOKEN=dpl_7c41e9a2"
      remote_repository "acme/toolkit", "Dockerfile" => DOCKERFILE, "Gemfile" => GEMFILE
      remote_repository_link "acme/toolkit", "Gemfile.lock" => target
      define_from_remote "toolkit", "acme/toolkit"

      farmy "start", "toolkit"

      assert_exit 1
      assert_stderr "Gemfile.lock"
      assert_stderr "outside the repository"
      refute_in_any_build_context "dpl_7c41e9a2"
      refute_stderr "dpl_7c41e9a2"
      refute_container "toolkit"
    end
  end

  test "a build file that is a link to the containers folder's .env by its absolute path stops the start, naming it, and nothing of that .env reaches a build context" do
    the_folder_env_also_holds "DEPLOY_TOKEN=dpl_7c41e9a2"
    remote_repository "acme/toolkit", "Dockerfile" => DOCKERFILE, "Gemfile" => GEMFILE
    remote_repository_link "acme/toolkit", "Gemfile.lock" => the_folder_env
    define_from_remote "toolkit", "acme/toolkit"

    farmy "start", "toolkit"

    assert_exit 1
    assert_stderr "Gemfile.lock"
    assert_stderr "outside the repository"
    refute_in_any_build_context "dpl_7c41e9a2"
    refute_container "toolkit"
  end

  test "a Dockerfile that is a link out of the repository stops the start, naming it, and nothing of what it points at reaches a build or the output" do
    the_folder_env_also_holds "DEPLOY_TOKEN=dpl_7c41e9a2"
    remote_repository "acme/toolkit", "Gemfile" => GEMFILE, "Gemfile.lock" => LOCKFILE
    remote_repository_link "acme/toolkit", "Dockerfile" => the_folder_env
    define_from_remote "toolkit", "acme/toolkit"

    farmy "start", "toolkit"

    assert_exit 1
    assert_stderr "Dockerfile"
    assert_stderr "outside the repository"
    refute_in_any_build_context "dpl_7c41e9a2"
    refute_stdout "dpl_7c41e9a2"
    refute_stderr "dpl_7c41e9a2"
  end

  test "a build_files entry ../.env is refused before anything is fetched, naming it, and the containers folder's .env is left as it was" do
    remote_repository "acme/toolkit", "Dockerfile" => DOCKERFILE, "Gemfile" => GEMFILE, "Gemfile.lock" => LOCKFILE
    define_toolkit_with_build_files "Gemfile", "../.env"

    farmy "start", "toolkit"

    assert_exit 1
    assert_stderr "../.env"
    assert_unchanged ".env"
    refute_container "toolkit"
  end

  test "a build_files entry naming the containers folder's .env by its absolute path is refused before anything is fetched, naming it, and that .env is left as it was" do
    remote_repository "acme/toolkit", "Dockerfile" => DOCKERFILE, "Gemfile" => GEMFILE, "Gemfile.lock" => LOCKFILE
    define_toolkit_with_build_files "Gemfile", the_folder_env

    farmy "start", "toolkit"

    assert_exit 1
    assert_stderr the_folder_env
    assert_unchanged ".env"
    refute_container "toolkit"
  end
end

