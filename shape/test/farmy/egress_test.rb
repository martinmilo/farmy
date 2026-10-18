# The mesh egress node (farmy.yml egress:): one farmy-egress container running tailscaled as a proxy on
# the farmy network; everything farmy starts gets the proxy variables. Nothing of it without egress:.
class EgressTest < AcceptanceTest
  def setup = workspace("workshop") # shop with postgres and redis sidecars, notes, toolkit; no farmy.yml

  test "with an authkey from the shim the egress node joins by itself and nothing is printed to register" do
    write_file "farmy.yml", fixture("farmy/egress.yml") # egress.authkey: TS_AUTHKEY, under secrets.unlock

    farmy "start", "shop", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"

    assert_success
    assert_running "farmy-egress", "shop"
    assert_given_on_stdin "farmy-egress", "tskey-auth-k9f2c1e5d7b"
    refute_stdout(/register/i)
  end

  test "the authkey is in no file, no docker command line and no inspect output" do
    write_file "farmy.yml", fixture("farmy/egress.yml")

    farmy "start", "shop", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"

    refute_secret_anywhere "tskey-auth-k9f2c1e5d7b"
  end

  test "without an authkey the registration URL from the node's log is printed once, with the instruction to register, and start goes on after join_timeout" do
    write_file "farmy.yml", fixture("farmy/egress-url.yml") # egress: join_timeout 2s, no authkey
    container_log "farmy-egress", "To authenticate, visit:\n\n\thttps://login.tailscale.com/a/9f2c1e5d7b\n\n"

    farmy "start", "shop"

    assert_success
    assert_url_printed_once "https://login.tailscale.com/a/9f2c1e5d7b"
    assert_stdout(/register/i)
    assert_running "shop"
  end

  test "a node registered before, its state on farmy-egress, joins again at the next start without printing anything" do
    write_file "farmy.yml", fixture("farmy/egress-url.yml")
    mesh_registered name: "mini.tail1234.ts.net", address: "100.101.102.103"

    farmy "start", "shop"

    assert_success
    assert_running "farmy-egress"
    refute_stdout(/register/i)
    refute_stdout "login.tailscale.com"
  end

  test "status --json shows the egress node with its mesh name and address, and status prints its line" do
    write_file "farmy.yml", fixture("farmy/egress-url.yml")
    mesh_registered name: "mini.tail1234.ts.net", address: "100.101.102.103"
    farmy "start", "shop"

    farmy "status", "--json"
    assert_equal({ "state" => "registered", "name" => "mini.tail1234.ts.net", "address" => "100.101.102.103", "registration_url" => nil, "proxy" => "farmy-egress:1055", "mode" => "kernel", "note" => nil }, egress_json)

    farmy "status"
    assert_stdout(/^egress\s+registered\s+mini\.tail1234\.ts\.net\s+100\.101\.102\.103/)
  end

  test "status --json shows an unregistered node with its registration URL" do
    write_file "farmy.yml", fixture("farmy/egress-url.yml")
    container_log "farmy-egress", "To authenticate, visit:\n\n\thttps://login.tailscale.com/a/9f2c1e5d7b\n\n"
    farmy "start", "shop"

    farmy "status", "--json"

    assert_equal "unregistered", egress_json["state"]
    assert_equal "https://login.tailscale.com/a/9f2c1e5d7b", egress_json["registration_url"]
  end

  test "every container farmy starts gets the proxy variables pointing at the egress node, and NO_PROXY for the local names" do
    write_file "farmy.yml", fixture("farmy/egress.yml")

    farmy "start", "shop", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"

    assert_env "shop", "HTTP_PROXY", "http://farmy-egress:1055"
    assert_env "shop", "http_proxy", "http://farmy-egress:1055"
    assert_env "shop", "HTTPS_PROXY", "http://farmy-egress:1055"
    assert_env "shop", "ALL_PROXY", "socks5h://farmy-egress:1055"
    assert_env "shop", "NO_PROXY", "localhost,127.0.0.1,host.docker.internal,shop,keys,postgres,redis,farmy,farmy-egress,farmy-knowledge"
    assert_env "shop-keys", "HTTPS_PROXY", "http://farmy-egress:1055"
    assert_env "shop-pg", "HTTPS_PROXY", "http://farmy-egress:1055"
    assert_env "shop-redis", "HTTPS_PROXY", "http://farmy-egress:1055"
    assert_env "farmy-knowledge", "HTTPS_PROXY", "http://farmy-egress:1055"
  end

  test "the egress node is on the farmy network, publishes nothing and keeps its state on the farmy-egress volume" do
    write_file "farmy.yml", fixture("farmy/egress.yml")

    farmy "start", "shop", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"

    assert_network "farmy-egress", "farmy"
    assert_publishes_nothing "farmy-egress"
    assert_mounted "farmy-egress", "farmy-egress", at: "/var/lib/tailscale"
  end

  test "the egress node is up before the provider is asked for anything, and the provider runs with the proxy variables" do
    write_file "farmy.yml", fixture("farmy/egress-provider.yml") # the authkey under unlock, bin/provider, a git route
    secrets_provider GIT_TOKEN: "frg_9c1e5d7b2a"

    farmy "start", "shop", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"

    assert_success
    assert_provider_saw_running "farmy-egress"
    assert_file "provider.log", includes: "HTTPS_PROXY=http://farmy-egress:1055"
    assert_loaded_into "shop-keys", "GIT_TOKEN"
  end

  test "the toolbox installs netcat-openbsd and the app container gets the socks address, for git over SSH through the proxy" do
    write_file "farmy.yml", fixture("farmy/egress.yml")

    farmy "start", "shop", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"

    assert_toolbox_installs "shop", "netcat-openbsd"
    assert_env "shop", "ALL_PROXY", "socks5h://farmy-egress:1055"
  end

  test "a login server of your own is given to the node: farmy's login command with the key carries --login-server=<url>" do
    write_file "farmy.yml", fixture("farmy/egress.yml").sub("  authkey: TS_AUTHKEY\n", "  authkey: TS_AUTHKEY\n  tailscale:\n    login_server: https://headscale.example.com\n")

    farmy "start", "shop", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"

    assert_success
    assert_login_command "farmy-egress", "--login-server=https://headscale.example.com"
  end

  test "an authkey that is not under secrets.unlock is refused, naming both" do
    write_file "farmy.yml", "egress:\n  authkey: TS_AUTHKEY\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "TS_AUTHKEY"
    assert_stderr "unlock"
    refute_container "shop"
  end

  test "without egress nothing is set and no egress container runs" do
    farmy "start", "shop"

    refute_container "farmy-egress"
    refute_env "shop", "HTTP_PROXY"
    refute_env "shop-keys", "HTTPS_PROXY"
    refute_env "farmy-knowledge", "HTTPS_PROXY"
  end

  test "stop with no name stops the egress node too, and destroy keeps its volume" do
    write_file "farmy.yml", fixture("farmy/egress.yml")
    farmy "start", "shop", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"

    farmy "stop"
    assert_stopped "farmy-egress", "shop"

    farmy "destroy", "shop", stdin: "y\n"
    assert_volume "farmy-egress"
  end
  test "the registration URL is read from the node's log on stderr, on its own line under To authenticate, visit:" do
    write_file "farmy.yml", fixture("farmy/egress-url.yml")
    container_log "farmy-egress", "2026/10/14 21:03:11 To authenticate, visit:\n\n\thttps://mesh.example.com/register/Ag2rvRkAtLCAsHUwK6jIz9Ew\n\n", on: :stderr

    farmy "start", "shop"

    assert_success
    assert_url_printed_once "https://mesh.example.com/register/Ag2rvRkAtLCAsHUwK6jIz9Ew"
  end

  test "the log is read through the whole wait: a URL that appears only after a few reads is still printed" do
    write_file "farmy.yml", fixture("farmy/egress-url.yml")
    container_log "farmy-egress", "To authenticate, visit:\n\n\thttps://mesh.example.com/register/Ag2rvRkAtLCAsHUwK6jIz9Ew\n\n", after: 3

    farmy "start", "shop"

    assert_success
    assert_url_printed_once "https://mesh.example.com/register/Ag2rvRkAtLCAsHUwK6jIz9Ew"
  end

  test "while start waits for registration farmy runs no tailscale up or login of its own: the node's one call is the container's" do
    write_file "farmy.yml", fixture("farmy/egress-url.yml")
    container_log "farmy-egress", "To authenticate, visit:\n\n\thttps://mesh.example.com/register/Ag2rvRkAtLCAsHUwK6jIz9Ew\n\n"

    farmy "start", "shop"

    refute_ran_in "farmy-egress", /tailscale (up|login)/
    assert_told "farmy-egress", "tailscaled"
  end

  test "with an authkey farmy runs one tailscale up with the key and never another" do
    write_file "farmy.yml", fixture("farmy/egress.yml")
    farmy "start", "shop", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"

    farmy "start", "notes", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"

    assert_ran_in_times "farmy-egress", "--auth-key", 1
  end

  test "a registered node comes back Running after its container restarts, without a word and without a new login" do
    write_file "farmy.yml", fixture("farmy/egress-url.yml")
    mesh_registered name: "mini.tail1234.ts.net", address: "100.101.102.103"
    farmy "start", "shop"
    docker "restart", "farmy-egress"

    farmy "start", "notes"

    refute_stdout(/register/i)
    refute_ran_in "farmy-egress", /tailscale (up|login)/
    farmy "status", "--json"
    assert_equal "registered", egress_json["state"]
  end

  test "while waiting, start prints a live line with the elapsed time, the limit and the URL" do
    write_file "farmy.yml", fixture("farmy/egress-url.yml")
    container_log "farmy-egress", "To authenticate, visit:\n\n\thttps://mesh.example.com/register/Ag2rvRkAtLCAsHUwK6jIz9Ew\n\n"

    farmy "start", "shop"

    assert_stdout(%r{egress: waiting for registration · \d+s of 2s · https://mesh.example.com/register/Ag2rvRkAtLCAsHUwK6jIz9Ew})
  end

  test "start shows its phases in order: egress, secrets, images, containers, clone" do
    write_file "farmy.yml", fixture("farmy/egress.yml")

    farmy "start", "shop", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"

    assert_stdout_order "== egress", "== secrets", "== images: shop", "== containers: shop", "== clone: shop"
  end
  test "without an authkey the node's own login command carries --login-server=<url>, and compose warns about no variable" do
    write_file "farmy.yml", fixture("farmy/egress-url.yml") + "  tailscale:\n    login_server: https://mesh.example.com\n"

    farmy "start", "shop"

    assert_success
    assert_login_command "farmy-egress", "--login-server=https://mesh.example.com"
    refute_stderr "variable is not set"
  end

  test "every compose file farmy writes for a start with egress holds no variable left for compose to fill" do
    write_file "farmy.yml", fixture("farmy/egress-url.yml") + "  tailscale:\n    login_server: https://mesh.example.com\n"

    farmy "start", "shop"

    assert_compose_files_resolved
  end

  test "with egress the fragment's services are on the farmy network too, so they resolve the egress node" do
    write_file "farmy.yml", fixture("farmy/egress.yml")

    farmy "start", "shop", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"

    assert_network "shop", "farmy"
    assert_network "shop-pg", "farmy"
    assert_network "shop-redis", "farmy"
  end

  test "with FARMY_EGRESS_PROXY every proxy variable points at that address instead" do
    write_file "farmy.yml", fixture("farmy/egress.yml")

    farmy "start", "shop", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n", env: { "FARMY_EGRESS_PROXY" => "proxy.example.net:3128" }

    assert_env "shop", "HTTPS_PROXY", "http://proxy.example.net:3128"
    assert_env "shop", "ALL_PROXY", "socks5h://proxy.example.net:3128"
    assert_env "shop-keys", "HTTP_PROXY", "http://proxy.example.net:3128"
  end

  test "a start with egress runs the node with the TUN device and NET_ADMIN, and its login accepts the tailnet's DNS" do
    write_file "farmy.yml", fixture("farmy/egress.yml")

    farmy "start", "shop", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"

    assert_success
    assert_device "farmy-egress", "/dev/net/tun"
    assert_capability "farmy-egress", "NET_ADMIN"
    assert_login_command "farmy-egress", "--accept-dns=true"
  end

  test "when the daemon refuses the TUN device the node runs in userspace mode, and start and status say only tailnet names resolve" do
    write_file "farmy.yml", fixture("farmy/egress.yml")
    docker_refuses_device "/dev/net/tun"

    farmy "start", "shop", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"
    assert_success
    assert_running "farmy-egress", "shop"
    refute_device "farmy-egress", "/dev/net/tun"
    assert_stderr "only names under the tailnet's suffix resolve"

    farmy "status", "--json"
    assert_equal "userspace", egress_json["mode"]
    assert_includes egress_json["note"], "only names under the tailnet's suffix resolve"
  end

  test "the status line names the egress mode" do
    write_file "farmy.yml", fixture("farmy/egress-url.yml")
    mesh_registered name: "mini.tail1234.ts.net", address: "100.101.102.103"
    farmy "start", "shop"

    farmy "status"

    assert_stdout(/^egress\s+registered\s+mini\.tail1234\.ts\.net\s+100\.101\.102\.103\s+kernel mode/)
  end

  test "with egress proxy every container and the provider get the proxy variables pointing at it, and no egress node runs" do
    write_file "farmy.yml", fixture("farmy/keys.yml") + "egress:\n  proxy: proxy.example.com:3128\n"
    secrets_provider GIT_TOKEN: "frg_9c1e5d7b2a"

    farmy "start", "shop"

    assert_success
    assert_env "shop", "HTTPS_PROXY", "http://proxy.example.com:3128"
    assert_env "shop", "http_proxy", "http://proxy.example.com:3128"
    assert_env "shop-keys", "HTTPS_PROXY", "http://proxy.example.com:3128"
    assert_file "provider.log", includes: "HTTPS_PROXY=http://proxy.example.com:3128"
    refute_container "farmy-egress"
  end

  test "with egress proxy no container gets ALL_PROXY, so SSH goes through the HTTP proxy" do
    write_file "farmy.yml", "egress:\n  proxy: proxy.example.com:3128\n"

    farmy "start", "shop"

    refute_env "shop", "ALL_PROXY"
    refute_env "shop", "all_proxy"
  end

  test "egress proxy together with tailscale or an authkey is refused, naming both" do
    write_file "farmy.yml", "secrets:\n  unlock: [TS_AUTHKEY]\negress:\n  proxy: proxy.example.com:3128\n  authkey: TS_AUTHKEY\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "proxy"
    assert_stderr "authkey"
    refute_container "shop"
  end

  test "status shows an egress proxy on its line and in the JSON" do
    write_file "farmy.yml", "egress:\n  proxy: proxy.example.com:3128\n"
    farmy "start", "shop"

    farmy "status"
    assert_stdout(/^egress\s+proxy\s+proxy\.example\.com:3128/)

    farmy "status", "--json"
    assert_equal({ "state" => "proxy", "name" => nil, "address" => nil, "registration_url" => nil, "proxy" => "proxy.example.com:3128", "mode" => "proxy", "note" => nil }, egress_json)
  end
end
