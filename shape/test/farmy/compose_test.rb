class ComposeTest < AcceptanceTest
  def setup = workspace("workshop") # shop's compose: postgres (container shop-pg, volume shop-pg-data, with a healthcheck) and redis (shop-redis, without)

  test "the compose services a definition lists run next to the app and are reached by their names" do
    farmy "start", "shop"

    assert_running "shop-pg", "shop-redis"
    assert_image "shop-pg", "postgres:18"
    assert_compose_service "shop-pg", "postgres"
  end

  test "the app container waits for a fragment service with a healthcheck to be healthy, and for the others to be started" do
    farmy "start", "shop"

    assert_waits_for "shop", "postgres", healthy: true
    assert_waits_for "shop", "redis"
    assert_started_before "shop-pg", "shop"
  end

  test "the volumes and networks a definition declares are passed on as they are" do
    write_file "services/shop.yml", fixture("definitions/shop-with-backnet.yml")

    farmy "start", "shop"

    assert_mounted "shop-pg", "shop-pg-data", at: "/var/lib/postgresql"
    assert_network "shop-pg", "shop-backnet"
  end

  test "${FARMY_PORT_<n>} in a fragment is the n-th port of the service's block" do
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nports: [\"3100:3000\"]\ncompose:\n  postgres:\n    image: postgres:18\n    container_name: shop-pg\n    ports: [\"127.0.0.1:${FARMY_PORT_32}:5432\"]\n"

    farmy "start", "shop"

    assert_publishes "shop-pg", "3132:5432"
  end

  test "a fragment that defines a service named app or keys is refused" do
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\ncompose:\n  app:\n    image: nginx\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "services/shop.yml"
    assert_stderr "app"
    refute_container "shop"
  end
end
