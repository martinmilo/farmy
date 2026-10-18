class StatusTest < AcceptanceTest
  def setup = workspace("workshop") # shop: ports ["3100:3000"]; notes: ["3200:5173", "3201:24678"]

  test "status shows a started service as running with its address" do
    farmy "start", "shop"

    farmy "status"

    assert_success
    assert_stdout(/^shop\s+running\b/)
    assert_stdout "http://localhost:3100"
  end

  test "status marks a service whose definition changed since it started" do
    farmy "start", "shop"
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nports: [\"3100:4000\"]\n"

    farmy "status"

    assert_stdout(/^shop\s.*definition changed/)
    assert_stdout "farmy restart shop"
  end

  test "status without Docker running is refused" do
    docker_is_down

    farmy "status"

    assert_exit 1
    assert_stderr "Docker"
  end

  test "url prints the service's address on the host" do
    farmy "url", "shop"

    assert_success
    assert_stdout "http://localhost:3100"
  end

  test "url with LAN_HOST in .env prints the address other machines use" do
    settings lan_host: "workshop.local"

    farmy "url", "shop"

    assert_stdout "http://workshop.local:3100"
  end

  test "url prints one line per published port" do
    farmy "url", "notes"

    assert_stdout "http://localhost:3200"
    assert_stdout "http://localhost:3201"
    assert_stdout_lines 2
  end

  test "run executes a command inside the app container" do
    farmy "start", "shop"

    farmy "run", "shop", "bin/rails", "db:migrate"

    assert_success
    assert_ran_in "shop", "bin/rails db:migrate"
  end

  test "run on a service that is not running is refused and start is pointed at" do
    farmy "run", "shop", "bin/rails", "db:migrate"

    assert_exit 1
    assert_stderr "not running"
    assert_stderr "farmy start shop"
  end
end
