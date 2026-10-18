class StopAndDestroyTest < AcceptanceTest
  def setup = workspace("workshop") # shop: postgres + redis; notes: start_after shop

  test "stopping shop keeps its containers and volumes but nothing of it runs" do
    farmy "start", "shop"

    farmy "stop", "shop"

    assert_success
    assert_stopped "shop", "shop-pg", "shop-redis", "shop-keys"
    assert_volume "shop-src", "shop-pg-data"
  end

  test "stop with no name stops everything, the shared container too" do
    farmy "start", "notes"

    farmy "stop"

    assert_success
    assert_stopped "shop", "notes", "farmy-knowledge"
  end

  test "stopping a service that is not running says so" do
    farmy "stop", "shop"

    assert_success
    assert_stdout "shop is not running"
  end

  test "destroy answered y removes the containers and volumes and keeps the definition" do
    farmy "start", "shop"

    farmy "destroy", "shop", stdin: "y\n"

    assert_success
    refute_container "shop", "shop-pg", "shop-redis", "shop-keys"
    refute_volume "shop-src", "shop-pg-data"
    assert_file "services/shop.yml"
  end

  test "destroy answered n leaves everything as it is" do
    farmy "start", "shop"

    farmy "destroy", "shop", stdin: "n\n"

    assert_running "shop", "shop-pg"
    assert_volume "shop-src", "shop-pg-data"
  end

  test "restart picks up a changed definition" do
    farmy "start", "shop"
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nports: [\"3100:4000\"]\n"

    farmy "restart", "shop"

    assert_success
    assert_publishes "shop", "3100:4000"
  end

  test "destroy removes the checkout volume even when an earlier farmy, not compose, made it" do
    docker "volume", "create", "shop-src" # made before compose, without its labels: compose's down -v leaves it
    farmy "start", "shop"

    farmy "destroy", "shop", stdin: "y\n"

    assert_success
    refute_volume "shop-src"
  end
end
