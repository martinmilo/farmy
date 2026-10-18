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
end
