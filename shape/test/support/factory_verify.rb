# On-demand verify: the agent runs the profile's verify command whenever it likes with farmy-verify, on a snapshot
# of its tree, in a container of its own (FORMATS.md, "On-demand verify"). The agent's command lines run for real in
# its container as the fake plays them (agent_plays' steps; FORMATS.md, "Docker in the tests").
#
#   verify_service                        shop as factory_service makes it, with factory verify: test and one iteration;
#                                         test/check.sh (protected) prints `args:` and each argument in brackets,
#                                         `checking src/app.txt` on stderr, then `src/app.txt says fixed` (exit 0) or
#                                         `src/app.txt does not say fixed yet` (exit 3); a comment in it says
#                                         `kept from the agent`, which it never prints
#   verify_service hidden: ["test/"], model: :token, verify: "lint", commands: {...}, sidecar: :health_checked
#   agent_plays({ steps: [{ run: "farmy-verify --name x" }, { writes: {...} }, { find: "text" }, { sleep: 0.5 }] })
#   assert_agent_got 2, exit: 0, stdout: "…", stderr: /…/   what the agent's 2nd step (a command line) got back
#   refute_agent_got 2, stdout: "…", stderr: "…"            what that step did not get on that stream
#   assert_arrived_apart 1, "first line", "second line", by: 1   the second text reached the agent at least 1 s after the first
#   assert_agent_found_nowhere "text"     the agent's find step saw the text in no file its container can see
#   verify_record 1, 2                    iteration-1.verify-2.log of the last run: its header fields (args parsed from
#                                         JSON, exit as a number) and "output", what follows the blank line
#   verify_containers                     the run's containers labelled farmy.role=verify, in the order they ran
#   assert_one_verify_at_a_time           no two verify containers of the run ran at the same time
#   verify_sidecars_unhealthy             every verify's sidecars are unhealthy
#   assert_verify_sidecar "postgres", original: "shop-pg"   a fresh copy in shop-run-<id>-verify, removed after the verify
#   assert_verify_has_no_way_out · assert_run_tmpfs "verify", "/scratch" · refute_verify_sidecars
#   refute_agent_reaches_docker_or_farmy  no Docker socket, no farmy binary in the agent's container; farmy never on its network
#   assert_agent_got_the_first 1, bytes: 4_194_304, stdout: "o", stderr: "e"   exactly the first bytes the command printed
#   assert_agent_got_at_most 1, bytes: 65_536            stdout and stderr together, farmy-verify's own last lines aside
#   assert_answered_while_the_first_verify_ran 9         the step's answer came before the run's first verify ended
#   assert_left_nothing_behind 9                         nothing new where the agent can write, from the list_writable
#                                                        step before step 9 to the one after it
#   assert_verify_header_lines_safe 1, 1                 one known key per header line, no control character in any
#   assert_verify_record_kept_the_first 1, 1, bytes: 4_194_304, of: "eo", reason: "…"   exit 125, the reason, the bytes
#   verify_containers_print_first 1_048_576              every verify container prints that much before its command
module FactoryVerify
  def verify_service(verify: "test", max_iterations: 1, **options)
    options[:gate] ||= { "kind" => "green", "health_timeout" => "2s" } if options[:sidecar]
    factory_service(check: fixture("factory/verify-check.sh"), verify: verify, max_iterations: max_iterations, **options)
    note_situation "test/check.sh prints `args:` and its arguments in brackets, `checking src/app.txt` on stderr, then " \
                   "`src/app.txt says fixed` (exit 0) or `src/app.txt does not say fixed yet` (exit 3). A comment in it says " \
                   "`kept from the agent`, which it never prints. The agent's steps run for real in its container " \
                   "(FORMATS.md, \"Docker in the tests\")."
  end

  def agent_steps = Array(docker_state["agent_steps"]).select { |s| s["run_id"].to_s == run_id.to_s }

  def agent_step(index, iteration)
    step = agent_steps.find { |s| s["index"] == index && s["iteration"].to_s == iteration.to_s && s.key?("run") }
    return step if step
    seen = agent_steps.map { |s| "iteration #{s["iteration"]} step #{s["index"]}: #{s["run"] ? "`#{s["run"]}`" : "find #{s["find"].inspect}"}" }
    flunk "Expected the agent of iteration #{iteration} to have run its step #{index}, a command line in its container; " \
          "#{seen.empty? ? "it ran no command line" : "it ran #{seen.join("; ")}"}.\n\n#{docker_situation}#{transcript}"
  end

  # A step's stdout or stderr as the agent got it; a line that printed a lot keeps it in a file.
  def step_stream(step, stream)
    file = step["#{stream}_file"]
    file ? File.binread(file).force_encoding(Encoding::UTF_8) : step[stream].to_s
  end

  def what_the_agent_got(step)
    out, err = %w[stdout stderr].map { |s| shown_stream(step_stream(step, s)) }
    "\n  `#{step["run"]}` in #{step["container"]} exited #{step["exit"]}#{" (killed when the agent ended)" if step["killed"]}." \
      "\n  stdout:\n#{out}\n  stderr:\n#{err}\n  (The fake runs an agent's command lines for real, its container's mounts mapped to their " \
      "folders: FORMATS.md, \"Docker in the tests\".)"
  end

  def shown_stream(text)
    return "    (nothing)" if text.empty?
    return text.gsub(/^/, "    ") if text.bytesize <= 4096
    "    (#{text.bytesize} bytes) the first 100: #{text.byteslice(0, 100).inspect}\n    … the last 300: #{text.byteslice(-300, 300).inspect}"
  end

  # What the agent got on stderr without the lines farmy-verify adds at its end (and the newline before them).
  def without_farmy_verify_lines(text) = text.b.sub(/\n?(?:farmy-verify: [^\n]*(?:\n|\z))+\z/n, "")

  def assert_agent_got(index, exit: nil, stdout: nil, stderr: nil, iteration: 1)
    step = agent_step(index, iteration)
    got = what_the_agent_got(step)
    assert_equal exit, step["exit"], "Expected the agent's step #{index} to exit #{exit}.#{got}#{transcript}" unless exit.nil?
    { "stdout" => stdout, "stderr" => stderr }.each do |stream, want|
      next if want.nil?
      text = step_stream(step, stream)
      assert want === text || (want.is_a?(String) && text.include?(want)),
             "Expected the agent's step #{index} to get #{want.inspect} on its #{stream}.#{got}#{transcript}"
    end
  end

  # The agent got exactly the first `bytes` bytes the command printed and nothing after them: only `stdout`
  # characters on stdout, only `stderr` characters on stderr (farmy-verify's own lines at the end aside).
  def assert_agent_got_the_first(index, bytes:, stdout:, stderr:, iteration: 1)
    step = agent_step(index, iteration)
    out = step_stream(step, "stdout").b
    err = without_farmy_verify_lines(step_stream(step, "stderr"))
    stray_out = out.bytesize - out.count(stdout)
    stray_err = err.bytesize - err.count(stderr)
    assert stray_out.zero? && stray_err.zero? && out.bytesize + err.bytesize == bytes,
           "Expected the agent to get the first #{bytes} bytes the command printed, stdout and stderr together, as they came, and " \
           "nothing after them: the command prints only #{stderr.inspect} on stderr, then only #{stdout.inspect} on stdout, far more " \
           "than #{bytes} bytes. The agent got #{out.bytesize} bytes on stdout (#{stray_out} not #{stdout.inspect}) and " \
           "#{err.bytesize} on stderr (#{stray_err} not #{stderr.inspect}), farmy-verify's own last lines aside: " \
           "#{out.bytesize + err.bytesize} together.#{what_the_agent_got(step)}#{transcript}"
  end

  # Everything the agent got, stdout and stderr together and farmy-verify's own last lines aside, is at most `bytes`.
  def assert_agent_got_at_most(index, bytes:, iteration: 1)
    step = agent_step(index, iteration)
    got = step_stream(step, "stdout").bytesize + without_farmy_verify_lines(step_stream(step, "stderr")).bytesize
    assert got <= bytes, "Expected the agent's step #{index} to get at most #{bytes} bytes, stdout and stderr together and " \
                         "farmy-verify's own last lines aside; it got #{got}.#{what_the_agent_got(step)}#{transcript}"
  end

  # The agent's step got its answer before the run's first verify container ended.
  def assert_answered_while_the_first_verify_ran(index, iteration: 1)
    step = agent_step(index, iteration)
    first = verify_containers.first
    assert first, "Expected a verify container (farmy.role=verify) in the run.\n\n#{docker_situation}#{transcript}"
    ended = first["ended_at"] || Float::INFINITY
    assert step["ended_at"] < ended,
           "Expected the agent's step #{index} (`#{step["run"]}`) to get its answer at once, while the first verify " \
           "(#{first["name"]}) still ran; it got it #{format("%.1f", step["ended_at"] - ended)} s after that verify " \
           "ended.#{what_the_agent_got(step)}#{transcript}"
  end

  # Nothing new where the agent's container can write, from the agent's listing just before its step to the one
  # just after it (list_writable steps: every writable mount of its container, its own tree included).
  def assert_left_nothing_behind(index, iteration: 1)
    step = agent_step(index, iteration)
    listings = agent_steps.select { |s| s.key?("listing") && s["iteration"].to_s == iteration.to_s }
    before = listings.select { |s| s["index"] < index }.max_by { |s| s["index"] }
    after = listings.select { |s| s["index"] > index }.min_by { |s| s["index"] }
    assert before && after, "Expected the agent to list where it can write before and after its step #{index}.#{transcript}"
    left = after["listing"] - before["listing"]
    assert_empty left, "Expected the agent's step #{index} (`#{step["run"]}`) to leave nothing behind anywhere the agent's " \
                       "container can write; just after it these were new: #{left.join(", ")}. (The fake lists every " \
                       "writable mount of the agent's container, as the container sees it.)#{what_the_agent_got(step)}#{transcript}"
  end

  def refute_agent_got(index, stdout: nil, stderr: nil, iteration: 1)
    step = agent_step(index, iteration)
    { "stdout" => stdout, "stderr" => stderr }.each do |stream, unwanted|
      next if unwanted.nil?
      refute step_stream(step, stream).include?(unwanted), "Expected the agent's step #{index} not to get #{unwanted.inspect} on its #{stream}.#{what_the_agent_got(step)}#{transcript}"
    end
  end

  # When each text first reached the agent (stdout and stderr together, in the order they came), in seconds after the
  # command line started.
  def assert_arrived_apart(index, first, second, by:)
    step = agent_step(index, 1)
    seen = +""
    at = {}
    Array(step["chunks"]).each do |chunk|
      seen << chunk["text"]
      [first, second].each { |text| at[text] ||= chunk["at"] - step["started_at"] if seen.include?(text) }
    end
    got = what_the_agent_got(step)
    assert at[first] && at[second], "Expected the agent's step #{index} to get #{first.inspect} and then #{second.inspect}.#{got}#{transcript}"
    assert at[second] - at[first] >= by,
           "Expected farmy-verify to pass the command's output on as it comes: the command prints #{first.inspect}, waits, then prints " \
           "#{second.inspect}, so the agent should get the first at least #{by} s before the second; it got them " \
           "#{format("%.1f", at[first])} s and #{format("%.1f", at[second])} s after it called.#{got}#{transcript}"
  end

  def assert_agent_found_nowhere(text)
    finds = agent_steps.select { |s| s["find"] == text }
    assert !finds.empty?, "Expected the agent to look for #{text.inspect} in its container; it never did.#{transcript}"
    finds.each do |f|
      assert f["found"].empty?, "Expected no file the agent's container (#{f["container"]}) can see to hold #{text.inspect}, which only the hidden " \
                                "folder holds; after the verify these hold it: #{f["found"].join(", ")}. farmy-verify gives the agent the " \
                                "command's output and exit code, never files.#{transcript}"
    end
  end

  def verify_record(iteration, k)
    name = "iteration-#{iteration}.verify-#{k}.log"
    text = run_record_text(name)
    head, output = text.split("\n\n", 2)
    fields = head.to_s.lines(chomp: true).to_h { |line| key, value = line.split(": ", 2); [key, value.to_s] }
    shape = "header lines `key: value` (args, command, commit, started, ended, exit, and reason when there is one), a blank line, then the output"
    assert fields.key?("args") && fields.key?("exit"), "Expected #{name} to start with #{shape}; it is:\n#{text}#{transcript}"
    begin
      fields["args"] = JSON.parse(fields["args"])
    rescue JSON::ParserError
      flunk "Expected the args line of #{name} to be a JSON array of the words farmy-verify was given; it is #{fields["args"].inspect}.#{transcript}"
    end
    fields["exit"] = Integer(fields["exit"]) if fields["exit"].match?(/\A\d+\z/)
    %w[command reason].each do |key|
      fields[key] = JSON.parse(fields[key]) if fields[key].to_s.start_with?('"')
    rescue JSON::ParserError
      nil
    end
    fields.merge("output" => output.to_s)
  end

  VERIFY_HEADER_KEYS = %w[args command commit started ended exit reason].freeze

  # Each header line of iteration-<i>.verify-<k>.log is `key: value`, its key known and there once, with no control
  # character in it; args is a JSON array, command and reason JSON strings.
  def assert_verify_header_lines_safe(iteration, k)
    name = "iteration-#{iteration}.verify-#{k}.log"
    head = run_record_text(name).split("\n\n", 2).first.to_s.lines(chomp: true)
    keys = head.map { |line| line[/\A([a-z]+): /, 1] }
    unknown = head.reject { |line| VERIFY_HEADER_KEYS.include?(line[/\A([a-z]+): /, 1]) }
    controls = head.select { |line| line.match?(/[\x00-\x1f\x7f]/) }
    twice = keys.compact.tally.select { |_, n| n > 1 }.keys
    missing = %w[args command commit started ended exit] - keys
    not_json = { "args" => Array, "command" => String, "reason" => String }.filter_map do |key, kind|
      line = head.find { |l| l.start_with?("#{key}: ") } or next
      key unless (JSON.parse(line.delete_prefix("#{key}: ")) rescue nil).is_a?(kind)
    end
    wrong = { "lines with no known key" => unknown.size, "lines holding a control character" => controls.size, "keys more than once" => twice,
              "keys missing" => missing, "values not JSON (args an array, command and reason strings)" => not_json }
    wrong = wrong.reject { |_, v| v == 0 || v == [] }
    assert wrong.empty?, "Expected every header line of #{name} to be `key: value`, its key one of #{VERIFY_HEADER_KEYS.join(", ")} " \
                         "and there once, with no control character in it: args a JSON array, command and reason JSON strings, so " \
                         "that a newline or control character in an argument is escaped and cannot start a line. Found: " \
                         "#{wrong.map { |k, v| "#{k}: #{v.is_a?(Array) ? v.join(", ") : v}" }.join("; ")}. Its header, each line " \
                         "escaped:\n#{head.map { |line| "    #{line.inspect}" }.join("\n")}#{transcript}"
  end

  # The record of a verify stopped at its output cap keeps what the agent got: exit 125, the reason, and as output
  # the first `bytes` bytes the command printed, only the characters `of` (a newline at the very end aside).
  def assert_verify_record_kept_the_first(iteration, k, bytes:, of:, reason:)
    record = verify_record(iteration, k)
    output = record["output"].b.delete_suffix("\n")
    stray = output.bytesize - output.count(of)
    assert record["exit"] == 125 && record["reason"].to_s.include?(reason) && stray.zero? && output.bytesize == bytes,
           "Expected iteration-#{iteration}.verify-#{k}.log to keep what the agent got: exit 125, a reason saying #{reason.inspect}, " \
           "and as its output the first #{bytes} bytes the command printed and nothing after them. It has exit " \
           "#{record["exit"].inspect}, reason #{record["reason"].inspect} and #{output.bytesize} bytes of output (#{stray} of " \
           "them not #{of.chars.join(" or ")}).#{transcript}"
  end

  def verify_containers_print_first(bytes)
    change_docker_state { |s| s["verify_print_first"] = bytes }
    note_situation "Every verify container prints #{bytes} bytes (`printed before the command` lines, alternately on stdout and " \
                   "stderr) before its command runs (FORMATS.md, \"Docker in the tests\")."
  end

  def verify_containers
    run_containers("verify").select { |r| r["labels"]["farmy.run"] == run_id }.sort_by { |r| r["seq"].to_i }
  end

  def assert_one_verify_at_a_time
    runs = verify_containers
    assert runs.size >= 2, "Expected two verify containers (farmy.role=verify), one per farmy-verify call; there #{runs.size == 1 ? "is one" : "are #{runs.size}"}.\n\n#{docker_situation}#{transcript}"
    runs.sort_by { |r| r["started_at"].to_f }.each_cons(2) do |a, b|
      assert b["started_at"].to_f >= a["ended_at"].to_f,
             "Expected one verify at a time in a run: #{b["name"]} started while #{a["name"]} still ran (#{format("%.1f", a["ended_at"].to_f - b["started_at"].to_f)} s together). " \
             "A second farmy-verify call waits until the first has ended.#{transcript}"
    end
  end

  def verify_sidecars_unhealthy
    change_docker_state { |s| s["verify_unhealthy"] = true }
    note_situation "Every verify's sidecars are unhealthy (docker inspect, and compose up --wait fails); the gate's are healthy."
  end

  def verify_projects(id = run_id) = Array(docker_state["verify_projects"]).select { |p| p["project"] == "shop-run-#{id}-verify" }

  def assert_verify_sidecar(service, original:)
    project = verify_projects.last
    assert project, "Expected the verify's own sidecars in a Compose project shop-run-#{run_id}-verify; there is none (projects: #{Array(docker_state["verify_projects"]).map { |p| p["project"] }.join(", ").then { |x| x.empty? ? "none" : x }}).\n\n#{docker_situation}#{transcript}"
    name, sidecar = project["containers"].find { |_, c| c["service"] == service }
    assert sidecar, "Expected a #{service} in shop-run-#{run_id}-verify.#{transcript}"
    refute_equal original, name, "Expected the verify's #{service} to be a fresh copy, not the developer's #{original}.#{transcript}"
    assert_empty Array(sidecar["ports"]), "Expected the verify's sidecars to publish no port.#{transcript}"
    verify = verify_containers.last
    shared = Array(verify && verify["networks"]) & Array(sidecar["networks"])
    assert !shared.empty?, "Expected the verify container on a network with its #{service} (#{Array(sidecar["networks"]).join(", ")}); it is on #{Array(verify && verify["networks"]).join(", ")}.#{transcript}"
    internal = verify_internal_networks
    outward = shared.reject { |n| internal[n] == true }
    assert_empty outward, "Expected the verify container and its #{service} on internal networks only; these are not internal: #{outward.join(", ")}.#{transcript}"
    assert (Array(container(original)&.fetch("networks", nil)) & shared).empty?, "Expected the developer's #{original} never on the verify's network.#{transcript}"
    left = docker_state["containers"].select { |_, c| c["project"] == "shop-run-#{run_id}-verify" }.keys
    assert_empty left, "Expected the verify's sidecars removed once it ended; still there: #{left.join(", ")}.#{transcript}"
  end

  def refute_verify_sidecars
    projects = Array(docker_state["verify_projects"]).map { |p| p["project"] }
    assert_empty projects, "Expected a verify on a gate with network none to start no sidecars; it started #{projects.join(", ")}.#{transcript}"
  end

  # Every network of every verify container is internal (no way out), or it has none at all.
  def assert_verify_has_no_way_out
    runs = verify_containers
    assert !runs.empty?, "Expected verify containers (farmy.role=verify) in the run.\n\n#{docker_situation}#{transcript}"
    internal = verify_internal_networks
    runs.each do |r|
      next if Array(r["networks"]) == ["none"]
      outward = Array(r["networks"]).reject { |n| internal[n] == true }
      assert !Array(r["networks"]).empty? && outward.empty?, "Expected the verify container #{r["name"]} with no way out: on internal networks only, or --network none; it is on #{Array(r["networks"]).map { |n| "#{n} (internal=#{internal[n].inspect})" }.join(", ").then { |x| x.empty? ? "no network given (the default bridge)" : x }}.#{transcript}"
    end
  end

  # Network name => internal or not, from every network made (docker network create, as it was made), the networks
  # there now, and the networks of the verifies' compose documents (compose removes them when the verify ends).
  def verify_internal_networks
    internal = Array(docker_state["networks_made"]).to_h { |n| [n["name"], n["internal"] == true] }
    docker_state["networks"].each { |name, n| internal[name] = n["internal"] == true unless internal.key?(name) }
    Array(docker_state["verify_projects"]).each do |p|
      (p["document"]["networks"] || { "default" => {} }).each do |key, conf|
        conf = {} unless conf.is_a?(Hash)
        internal[conf["name"] || "#{p["project"]}_#{key}"] = conf["internal"] == true unless conf["external"]
      end
    end
    internal
  end

  def assert_run_tmpfs(role, target)
    runs = run_containers(role)
    assert !runs.empty?, "Expected #{role} containers in the run.\n\n#{docker_situation}#{transcript}"
    runs.each do |r|
      assert Array(r["tmpfs"]).any? { |t| t["target"] == target }, "Expected the #{role} container #{r["name"]} to have a scratch tmpfs at #{target} (--tmpfs #{target}:exec), as the gate's test container has; its tmpfs: #{Array(r["tmpfs"]).map { |t| t["target"] }.join(", ").then { |x| x.empty? ? "none" : x }}.#{transcript}"
    end
  end

  def refute_agent_reaches_docker_or_farmy
    program = Target.path(PROGRAM)
    run_containers("agent").each do |r|
      sources = Array(r["binds"]).map { |b| b["source"].to_s } + Array(r["mounts"]).map { |m| m["name"].to_s }
      socket = sources.find { |s| s.include?("docker.sock") }
      assert_nil socket, "Expected no Docker socket in the agent's container #{r["name"]}; it mounts #{socket}.#{transcript}"
      binary = Array(r["binds"]).find { |b| File.file?(b["source"].to_s) && File.file?(program) && File.identical?(b["source"].to_s, program) }
      assert_nil binary, "Expected no farmy binary in the agent's container #{r["name"]}; it binds #{binary && binary["source"]} at #{binary && binary["target"]}.#{transcript}"
      joined = Array(docker_state["network_joins"]).select { |j| j["action"] == "connect" && j["container"] == "farmy" && Array(r["networks"]).include?(j["network"]) }
      assert_empty joined, "Expected the control container farmy never on the agent's network; it joined #{joined.map { |j| j["network"] }.join(", ")}.#{transcript}"
    end
  end
end
