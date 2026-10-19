# Docker and PostgreSQL observations used by the concurrency scenarios. A fake psql client discovers
# the sidecar through the gate's actual networks and persists SQL data on that sidecar's actual volume.
module FactoryPipelines
  def database_factory(gate_setup: true)
    work = { gate: { "kind" => "green", "health_timeout" => "1s" } }
    work[:gate_setup] = "schema" if gate_setup
    profiled_factory work: work, files: { "test/database-check.sh" => fixture("factory/database-check.sh") },
                     commands: { "test" => "sh test/database-check.sh", "schema" => "psql -h postgres -U dev -d app -c 'CREATE TABLE gate_values (value text); CREATE TABLE gate_release (released boolean)'" }
    change_factory_definition do |definition|
      definition["compose"] = { "postgres" => { "image" => "postgres:18", "container_name" => "shop-pg",
        "volumes" => ["pgdata:/var/lib/postgresql/data"], "ports" => ["127.0.0.1:3132:5432"],
        "healthcheck" => { "test" => ["CMD", "pg_isready"], "interval" => "1s", "retries" => 1 } } }
      definition["volumes"] = { "pgdata" => { "name" => "shop-pg-data" } }
    end
    farmy "restart", "shop"
    assert_success
    folder = volume_folder("shop-pg-data")
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "postgres-data.json"), JSON.generate("tables" => ["gate_values", "gate_release"], "values" => ["developer"], "released" => true))
  end

  def unsafe_gate_sidecar(kind)
    change_factory_definition do |definition|
      postgres = definition.fetch("compose").fetch("postgres")
      case kind
      when "privileged" then postgres["privileged"] = true
      when "Docker socket" then postgres["volumes"] << "/var/run/docker.sock:/var/run/docker.sock"
      when "host networking" then postgres["network_mode"] = "host"
      when "external network"
        postgres["networks"] = ["shared-network"]
        definition["networks"] = { "shared-network" => { "external" => true } }
      end
    end
  end

  def gate_sidecars_unhealthy
    change_docker_state { |state| state["gate_unhealthy"] = true }
  end

  def require_cobalt_after_database_check
    change_factory_definition do |definition|
      definition["commands"]["test"] = "sh test/database-check.sh && test \"$(cat src/app.txt)\" = cobalt"
    end
  end

  def gate_projects = Array(docker_state["gate_projects"])

  def assert_gate_sidecar_copy(id, service:, original:)
    project = gate_projects.find { |item| item["project"] == "shop-run-#{id}-gate" }
    assert project, "Expected a separate Compose project shop-run-#{id}-gate containing the run's own #{service}; no developer sidecar joins the gate.#{transcript}"
    members = project.fetch("containers")
    name, sidecar = members.find { |_, item| item["service"] == service }
    assert sidecar, "Expected a #{service} sidecar copy in #{project['project']}.#{transcript}"
    refute_equal original, name, "Expected the gate sidecar copy to ignore the developer's fixed container_name #{original}.#{transcript}"
    assert_empty sidecar["ports"], "Expected no host ports published from gate sidecars.#{transcript}"
    gates = run_containers("test").select { |gate| gate["name"].to_s.include?(id) }
    assert gates.any? { |gate| !(Array(gate["networks"]) & Array(sidecar["networks"])).empty? }, "Expected the gate to reach its #{service} copy through their internal run network.#{transcript}"
    internal = Array(docker_state["networks_made"]).to_h { |network| [network["name"], network["internal"] == true] }
    (project.fetch("document")["networks"] || {}).each do |key, configuration|
      configuration = {} unless configuration.is_a?(Hash)
      next if configuration["external"]
      network = configuration["name"] || "#{project['project']}_#{key}"
      internal[network] = configuration["internal"] == true
    end
    attached = (gates.flat_map { |gate| Array(gate["networks"]) } + Array(sidecar["networks"])).uniq
    outward = attached.reject { |network| internal[network] == true }
    assert_empty outward, "Expected the run's gate and #{service} copy on internal networks only; these attachments lack internal:true in the retained Compose/network-create evidence: #{outward.join(', ')}.#{transcript}"
    assert container(original), "Expected the developer's #{original} sidecar to survive the gate.#{transcript}"
    assert (Array(container(original)["networks"]) & Array(sidecar["networks"])).empty?, "Expected the developer's #{original} never to join the run gate network.#{transcript}"
  end

  def database_queries
    path = File.join(docker_journal, "postgres-queries.jsonl")
    File.exist?(path) ? File.readlines(path).filter_map { |line| JSON.parse(line) rescue nil } : []
  end

  def wait_database_gate(marker)
    deadline = Time.now + 45
    loop do
      return if database_queries.any? { |query| query["sql"] == "SELECT value FROM gate_values ORDER BY value" && query["result"] == "#{marker}\n" }
      break if Time.now >= deadline
      sleep 0.05
    end
    flunk "Expected the live gate to insert and read only #{marker.inspect} through psql -h postgres before reaching its database barrier. Queries: #{database_queries.inspect}.#{transcript}"
  end

  def two_live_database_runs
    agent_plays({ writes: { "src/app.txt" => "amber\n" } }, { writes: { "src/app.txt" => "cobalt\n" } })
    factory_start profile: "work", wait: false
    assert_success
    first = run_id
    wait_database_gate "amber"
    factory_start profile: "work", wait: false
    assert_success
    second = run_id
    wait_database_gate "cobalt"
    [first, second]
  end

  def release_database_gate(marker)
    query = database_queries.find { |q| q["result"] == "#{marker}\n" }
    assert query, "Expected a live database containing #{marker.inspect} before release.#{transcript}"
    folder = volume_folder(query.fetch("volume"))
    File.open(File.join(folder, "postgres-data.lock"), "a+") do |lock|
      lock.flock(File::LOCK_EX)
      path = File.join(folder, "postgres-data.json")
      database = JSON.parse(File.read(path))
      database["released"] = true
      temporary = "#{path}.release"
      File.write(temporary, JSON.generate(database))
      File.rename(temporary, path)
    end
  end

  def assert_distinct_gate_databases(first, second)
    projects = gate_projects.select { |item| ["shop-run-#{first}-gate", "shop-run-#{second}-gate"].include?(item["project"]) }
    assert_equal 2, projects.size, "Expected two overlapping runs to create separate sidecar Compose projects.#{transcript}"
    volumes = projects.map { |item| item.fetch("containers").values.find { |c| c["service"] == "postgres" }.fetch("volumes").find { |v| v["target"].start_with?("/var/lib/postgresql") }.fetch("name") }
    assert_equal 2, volumes.uniq.size, "Expected each live gate to have its own fresh database data volume.#{transcript}"
    refute_includes volumes, "shop-pg-data", "Expected gate databases not to use the developer's database volume.#{transcript}"
    assert_gate_sidecar_copy first, service: "postgres", original: "shop-pg"
    assert_gate_sidecar_copy second, service: "postgres", original: "shop-pg"
  end

  def assert_database_isolation
    reads = database_queries.select { |query| query["sql"] == "SELECT value FROM gate_values ORDER BY value" }
    assert_equal ["amber\n", "cobalt\n"], reads.map { |query| query["result"] }.uniq.sort, "Expected overlapping gates each to read only their own SQL row, never each other's or the developer's row.#{transcript}"
    assert_equal 2, reads.map { |query| query["volume"] }.uniq.size, "Expected SQL access to use two independent sidecar volumes.#{transcript}"
  end

  def assert_gate_resources_removed(id)
    state = docker_state
    project = "shop-run-#{id}-gate"
    assert_empty state["containers"].select { |_, item| item["project"] == project }, "Expected cancelled or finished run #{id}'s gate sidecars to be removed.#{transcript}"
    assert_empty state["volumes"].select { |_, item| item["project"] == project }, "Expected run #{id}'s fresh gate database volumes to be removed.#{transcript}"
    assert_empty state["networks"].select { |_, item| item["project"] == project }, "Expected run #{id}'s gate Compose networks to be removed.#{transcript}"
  end

  def assert_database_gate_alive(id, marker:)
    project = "shop-run-#{id}-gate"
    members = docker_state["containers"].values.select { |item| item["project"] == project }
    assert members.any? { |item| item["service"] == "postgres" && item["state"] == "running" }, "Expected cancelling another run to leave #{id}'s postgres sidecar running.#{transcript}"
    query = database_queries.find { |item| item["result"] == "#{marker}\n" }
    data = query && JSON.parse(File.read(File.join(volume_folder(query["volume"]), "postgres-data.json")))
    assert_equal [marker], data && data["values"], "Expected surviving gate #{id}'s database to retain only #{marker.inspect}.#{transcript}"
  end

  def assert_developer_database_untouched
    assert container("shop-pg") && container("shop-pg")["state"] == "running", "Expected the developer's database container to remain running.#{transcript}"
    path = File.join(volume_folder("shop-pg-data"), "postgres-data.json")
    assert File.file?(path), "Expected the developer's database volume to survive run cleanup.#{transcript}"
    assert_equal ["developer"], JSON.parse(File.read(path))["values"], "Expected the developer's database rows never to be used or removed by a gate.#{transcript}"
  end

  def wait_run(id, result:, within: 45)
    deadline = Time.now + within
    loop do
      farmy "status", "--json"
      run = service_json("shop").fetch("runs", []).find { |item| item["id"] == id }
      return if run && run["result"] == result
      break if Time.now >= deadline
      sleep 0.05
    end
    assert_run_status id, result: result
  end

  def assert_schema_before_test
    queries = database_queries
    created = queries.index { |query| query["sql"].start_with?("CREATE TABLE gate_values") }
    inserted = queries.index { |query| query["sql"].start_with?("INSERT INTO gate_values") }
    assert created && inserted && created < inserted, "Expected gate_setup schema SQL against healthy fresh sidecars before the gate test's first INSERT. Queries: #{queries.inspect}.#{transcript}"
    assert_equal queries[created]["volume"], queries[inserted]["volume"], "Expected setup and test to reach the same fresh database.#{transcript}"
  end

  def assert_factory_queued(id)
    farmy "status", "--json"
    assert_run_status id, phase: "queued"
  end

  def assert_no_gate_projects
    assert_empty gate_projects, "Expected gate.network none to create no sidecar Compose project.#{transcript}"
  end

  def assert_queued_count(count)
    farmy "status", "--json"
    queued = service_json("shop").fetch("runs", []).select { |run| run["phase"] == "queued" }
    assert_equal count, queued.size, "Expected #{count} runs queued while the service's execution slots are occupied.#{transcript}"
  end

  def another_factory_service
    write_file "services/catalogue.yml", read_file("services/shop.yml")
    farmy "start", "catalogue"
    assert_success
    change_docker_state do |state|
      (state["agent_plays"] ||= {})["catalogue"] = [{ "writes" => { "src/app.txt" => "fixed\n" } }]
    end
  end
end
