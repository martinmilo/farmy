# What the TUI renders from: the data, so that the tests pin it and not the drawing.
class StatusJsonTest < AcceptanceTest
  def setup = workspace("workshop") # shop: ports 3100:3000, postgres (with a healthcheck) and redis; notes: 3200:5173 3201:24678

  test "status --json lists every service with its state, block, repository and commands" do
    farmy "start", "shop"

    farmy "status", "--json"

    assert_success
    assert_equal "running", service_json("shop")["state"]
    assert_equal "3100-3199", service_json("shop")["block"]
    assert_equal "https://github.com/acme/shop.git", service_json("shop")["repo"]
    assert_equal %w[setup start test], service_json("shop")["commands"]
    assert_equal "stopped", service_json("notes")["state"]
  end

  test "status --json lists every container of a service with its state and its health when it has a healthcheck" do
    farmy "start", "shop"

    farmy "status", "--json"

    containers = service_json("shop")["containers"]
    assert_equal({ "name" => "shop-pg", "service" => "postgres", "state" => "running", "health" => "healthy" }, containers.find { |c| c["name"] == "shop-pg" })
    assert_equal({ "name" => "shop-redis", "service" => "redis", "state" => "running", "health" => nil }, containers.find { |c| c["name"] == "shop-redis" })
    assert_equal %w[shop shop-keys shop-pg shop-redis], containers.map { |c| c["name"] }.sort
  end

  test "status --json says for each ports pair whether something listens on the container port" do
    farmy "start", "notes" # 3200:5173 and 3201:24678
    listening "notes", 5173

    farmy "status", "--json"

    ports = service_json("notes")["ports"]
    assert_equal({ "host" => 3200, "container" => 5173, "url" => "http://localhost:3200", "lan_url" => nil, "listening" => true }, ports[0])
    assert_equal false, ports[1]["listening"]
  end

  test "status --json gives the LAN address of each port when LAN_HOST is set" do
    settings lan_host: "workshop.local"
    farmy "start", "shop"

    farmy "status", "--json"

    assert_equal "workshop.local", status_json["lan_host"]
    assert_equal "http://workshop.local:3100", service_json("shop")["ports"][0]["lan_url"]
    assert_equal "http://localhost:3100", service_json("shop")["ports"][0]["url"]
  end

  test "status --json shows an agent's state from the status file its hooks write" do
    write_file "farmy.yml", "agents:\n  claude: {}\n"
    farmy "start", "shop"
    volume_file "shop-agents", "claude/agent.status", "working\t2026-10-13T17:58:10Z\n"

    farmy "status", "--json"

    assert_equal({ "state" => "working", "since" => "2026-10-13T17:58:10Z", "source" => "hooks" }, agent_json("shop", "claude"))
  end

  test "status --json falls back to the processes in the container when there is no status file" do
    write_file "farmy.yml", "agents:\n  claude: {}\n"
    farmy "start", "shop"
    process_in "shop", "claude"

    farmy "status", "--json"

    assert_equal({ "state" => "running", "since" => nil, "source" => "process" }, agent_json("shop", "claude"))
  end

  test "status --json shows null for ports and agents of a service that is not running" do
    farmy "status", "--json"

    assert_success
    assert_nil service_json("notes")["ports"][0]["listening"]
    assert_nil service_json("notes")["agents"]
  end
end
