# Factory logins: an agent's own login volume, made by `farmy factory login <service> <agent>`, mounted read-write
# by that agent's factory containers in mode: login. The fake docker plays a login container (farmy.role=login).
#
#   login_factory                       shop with two profiles: shape (claude, api-key) and work (codex, mode: login)
#   login_factory agent: "mytool", extra_config: mytool_agent(factory_login: …)   work runs an agent of your own
#   factory_login "codex"               farmy factory login shop codex
#   logged_in "codex"                   the same, which must succeed
#   login_fails                         the login container's command fails (exit 1)
#   login_containers                    the docker runs labelled farmy.role=login
#   assert_login_ran "codex", at: "/home/dev/.codex", line: "codex login --device-auth"   one login container: farmy/shop:dev,
#                                       user dev, the agent's volume at that path, writable, running that line
#   assert_login_goes_out_like_the_git_helpers   on shop_default, joined to farmy
#   give_mytool_factory_login "{path: …, create: …}"   farmy.yml's mytool gets that factory_login, after start
#   wait_for_factory_phase "login_wait" farmy factory list shows a run in that phase (within 20 s)
module FactoryLogins
  def login_factory(agent: "codex", extra_config: "")
    profiled_factory work: { agent: agent, mode: "login" }, extra_config: extra_config
    note_situation "Profile work runs #{agent} in mode: login."
  end

  def factory_login(agent) = farmy("factory", "login", "shop", agent)

  def logged_in(agent)
    factory_login agent
    assert finished.exit.zero?, "Expected farmy factory login shop #{agent} to succeed.#{transcript}"
    note_situation "farmy factory login shop #{agent} made #{agent}'s factory login."
  end

  def login_fails
    change_docker_state { |s| s["login_fails"] = true }
    note_situation "The login command fails in the login container (exit 1)."
  end

  def login_containers = docker_state["runs"].select { |r| (r["labels"] || {})["farmy.role"] == "login" }

  def assert_login_ran(agent, at:, line:)
    runs = login_containers
    assert runs.size == 1, "Expected one container labelled farmy.role=login; there are #{runs.size}.\n\n#{docker_situation}#{transcript}"
    r = runs.first
    assert_equal "farmy/shop:dev", r["image"], "Expected the login container to run the service image."
    assert_equal "dev", r["user"].to_s.split(":").first, "Expected the login container to run as dev (-u dev)."
    m = Array(r["mounts"]).find { |x| x["target"] == at }
    assert m && m["name"] == "farmy-factory-login-#{agent}" && !m["ro"], "Expected the login container to mount farmy-factory-login-#{agent} at #{at}, writable; it mounts #{Array(r["mounts"]).map { |x| "#{x["name"]} at #{x["target"]}#{x["ro"] ? " (ro)" : ""}" }.join(", ").then { |x| x.empty? ? "nothing" : x }}.#{transcript}"
    assert Array(r["process"]).include?(line), "Expected the login container to run #{line.inspect} (sh -c #{line}); its process is #{Array(r["process"]).inspect}.#{transcript}"
  end

  def assert_login_goes_out_like_the_git_helpers
    r = login_containers.first or flunk("Expected a login container.#{transcript}")
    assert_equal %w[farmy shop_default], Array(r["networks"]).sort, "Expected the login container on the service network shop_default and joined to farmy (docker create --network shop_default, docker network connect farmy, docker start -a -i), as the factory git containers are; it is on #{Array(r["networks"]).join(", ").then { |x| x.empty? ? "none" : x }}.#{transcript}"
  end
  
  def give_mytool_factory_login(value)
    write_file "farmy.yml", read_file("farmy.yml").sub("    headless_login: null\n", "    headless_login: null\n    factory_login: #{value}\n")
    note_situation "farmy.yml's mytool now declares factory_login: #{value}."
  end

  def wait_for_factory_phase(phase)
    deadline = Time.now + 20
    loop do
      farmy "factory", "list"
      break if stdout.include?(phase) || Time.now > deadline
      sleep 0.2
    end
    assert_stdout phase
  end
end

# Orphans of a login turn: an agent container still running after its controller died.
#
#   assert_still_running "shop-run-<id>-agent-1" · refute_running "…"   docker ps lists it as running, or not
#   assert_stopped_before_started orphan, agent   docker's call log stops or removes the orphan before the docker run of agent
#   another_folders_login_agent "codex"   a running agent container of codex's factory login, made by another
#                                       containers folder's farmy (service other, a run this folder never had)
#   orphans_stopped                     the last run's state.json orphans_stopped ([] when absent)
#   orphaned_codex_agent                login_factory, codex logged in; a work run whose controller was killed while its
#                                       agent (the first play) runs: returns [that run's id, its agent container]
#   removal_fails orphan, times: 2      docker rm of that container fails that many times (times: :always)
#   assert_removal_tried orphan, at_least: 3   docker's call log has that many docker rm of it
module FactoryLoginOrphans
  def assert_still_running(name)
    c = container(name)
    assert c && c["state"] == "running", "Expected #{name} to be running#{c ? "; it is #{c["state"]}" : "; Docker has no such container"}.\n\n#{docker_situation}#{transcript}"
  end

  def refute_running(name)
    c = container(name)
    assert c.nil? || c["state"] != "running", "Expected #{name} to be stopped or removed (docker rm -f); it is still running.\n\n#{docker_situation}#{transcript}"
  end

  def assert_stopped_before_started(orphan, agent)
    calls = docker_call_words
    stop = calls.index { |w| (%w[stop kill].include?(w.first) || (w.first == "rm" && (w.include?("-f") || w.include?("--force")))) && w.include?(orphan) }
    start = calls.index { |w| w.first == "run" && w.each_cons(2).include?(["--name", agent]) }
    assert stop, "Expected farmy to stop the orphaned agent container #{orphan} (docker rm -f #{orphan}); no docker call did.\n\n#{docker_situation}#{transcript}"
    assert start && stop < start, "Expected #{orphan} stopped before #{agent} started; #{start ? "the docker run of #{agent} came first" : "#{agent} never started"}.\n\n#{docker_situation}#{transcript}"
  end

  def another_folders_login_agent(agent)
    name = "other-run-20261019-070000-abcd-agent-1"
    change_docker_state do |s|
      s["containers"][name] = { "project" => nil, "service" => nil, "image" => "farmy/other:dev", "command" => ["sh", "-c", "codex exec -"],
        "state" => "running", "labels" => { "farmy.run" => "20261019-070000-abcd", "farmy.service" => "other", "farmy.role" => "agent",
        "farmy.iteration" => "1", "farmy.factory-login" => agent }, "ports" => [], "env" => {}, "init" => false, "volumes" => [],
        "binds" => [], "networks" => ["other-run-20261019-070000-abcd"], "workdir" => nil, "started_seq" => 1, "compose_file" => nil,
        "process" => ["sh", "-c", "codex exec -"], "aliases" => [] }
    end
    note_situation "Another containers folder's run 20261019-070000-abcd (service other) has its agent #{name} running on #{agent}'s factory login."
    name
  end

def orphaned_codex_agent
  login_factory
  logged_in "codex"
  agent_plays({ barrier: "orphaned", writes: { "src/app.txt" => "almost\n" } }, { writes: { "src/app.txt" => "fixed\n" } })
  factory_start profile: "work", wait: false
  first = run_id
  wait_agent_barrier "orphaned"
  kill_controller first
  orphan = "shop-run-#{first}-agent-1"
  assert_still_running orphan
  [first, orphan]
end

def removal_fails(name, times:)
  change_docker_state { |s| (s["rm_fails"] ||= {})[name] = times == :always ? -1 : times }
  note_situation "docker rm of #{name} fails #{times == :always ? "every time" : "#{times} times"}: \"could not kill: permission denied\"."
end

def assert_removal_tried(name, at_least:)
  tries = docker_call_words.count { |w| w.first == "rm" && w.include?(name) }
  assert tries >= at_least, "Expected farmy to try docker rm -f #{name} at least #{at_least} times before giving up; it tried #{tries}.\n\n#{docker_situation}#{transcript}"
end

  def orphans_stopped = Array(run_state["orphans_stopped"])
end
