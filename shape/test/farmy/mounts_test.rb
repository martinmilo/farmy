class MountsTest < AcceptanceTest
  def setup = workspace("workshop") # shop: image ruby:3.4, checkout on shop-src at /workspace

  test "a mount keeps a folder of the app container on a volume named after the service and the mount" do
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nmounts:\n  bundle: /usr/local/bundle\n  cache: /home/dev/.cache\n"

    farmy "start", "shop"

    assert_success
    assert_mounted "shop", "shop-bundle", at: "/usr/local/bundle"
    assert_mounted "shop", "shop-cache", at: "/home/dev/.cache"
    assert_mounted "shop", "shop-src", at: "/workspace"
  end

  test "stop and restart keep a mount's volume, destroy removes it" do
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nmounts:\n  bundle: /usr/local/bundle\n"
    farmy "start", "shop"

    farmy "stop", "shop"
    assert_volume "shop-bundle"

    farmy "restart", "shop"
    assert_volume "shop-bundle"
    assert_mounted "shop", "shop-bundle", at: "/usr/local/bundle"

    farmy "destroy", "shop", stdin: "y\n"
    refute_volume "shop-bundle"
  end

test "every app container mounts farmy-shared at /home/dev/.farmy-shared and nothing named dev-tooling" do
  farmy "start", "notes" # starts shop first

  assert_mounted "shop", "farmy-shared", at: "/home/dev/.farmy-shared"
  assert_mounted "notes", "farmy-shared", at: "/home/dev/.farmy-shared"
  refute_mounted "shop", "dev-tooling"
  refute_volume "dev-tooling"
end

test "destroy removes the service's own volumes and keeps farmy-shared" do
  write_file "farmy.yml", "agents:\n  claude: {}\n"
  farmy "start", "shop"

  farmy "destroy", "shop", stdin: "y\n"

  refute_volume "shop-agents", "shop-src"
  assert_volume "farmy-shared"
end

  test "a mount named src is refused: /workspace is the checkout's volume already" do
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nmounts:\n  src: /srv\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "services/shop.yml"
    assert_stderr "src"
    refute_container "shop"
  end

  test "a service with shared_logins: false exposes no shared login folders and keeps its agents' logins on its own volume" do
    write_file "farmy.yml", "agents:\n  claude: {}\n"
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nshared_logins: false\n"

    farmy "start", "shop"

    assert_no_shared_logins "shop"
    assert_mounted "shop", "shop-agents", at: "/home/dev/.farmy-service"
    assert_env "shop", "FARMY_LOGIN_DIR", "/home/dev/.farmy-service/logins"
  end

  test "every other service links its agents' logins into farmy-shared" do
    write_file "farmy.yml", "agents:\n  claude: {}\n"

    farmy "start", "shop"

    assert_mounted "shop", "farmy-shared", at: "/home/dev/.farmy-shared"
    assert_env "shop", "FARMY_LOGIN_DIR", "/home/dev/.farmy-shared"
  end
end
