# How the shim obtains the unlocking values (secrets.unlock in farmy.yml) before it hands a command
# to the control container: a store on the PATH, an unlock command, else a prompt. The stores are the
# fakes in support/fakes/stores (security plays the macOS Keychain, secret-tool the Linux secret
# service); a test puts one on the PATH, and the fake docker shows what farmy then received on stdin.
#
#   shim_workspace "workshop"                                the fixture, the control container up (farmy init through the shim)
#   keychain "farmy/INFISICAL_TOKEN" => "st.d41d8cd9"        the fake security on the PATH, holding these generic passwords
#   keychain ["farmy", "INFISICAL_TOKEN"] => "…", locked: true   service and account (the old form); locked until unlock-keychain
#   secret_service "farmy farmy/INFISICAL_TOKEN" => "…"      the fake secret-tool on the PATH, an item per "attr value attr value"
#   secret_service({}, unreachable: true)                    one that answers every lookup with an error (no D-Bus session)
#   unlock_command "pass show farmy/$1"                      FARMY_UNLOCK_COMMAND for the shim
#   assert_store_asked "find-generic-password -s farmy/INFISICAL_TOKEN -w"   the store saw this call (times: n to count)
#   assert_passed_to_farmy "INFISICAL_TOKEN=st.d41d8cd9"     farmy in the control container received this line on stdin
#   refute_passed_to_farmy "INFISICAL_TOKEN"                 no line for that name reached it
#   assert_guide_says "docs/credentials.md", "never stores a secret on disk", …   a guide in the work folder holds these phrases
module Unlock
  STORES = File.join(TEST_ROOT, "support", "fakes", "stores")

  def shim_workspace(name)
    workspace(name)
    shim "init"
    note_situation "The control container is up (farmy init through the shim)."
  end

  def keychain(entries = nil, locked: false, **given)
    entries ||= given
    items = entries.map do |key, password|
      service, account = key.is_a?(Array) ? key : [key, nil]
      { "service" => service, "account" => account, "password" => password }
    end
    store_on_path "security", "FAKE_SECURITY", "locked" => locked, "items" => items
    note_situation "The Keychain (a fake security on the PATH)#{" is locked and" if locked} holds: #{entries.empty? ? "nothing" : entries.keys.map { |k| k.is_a?(Array) ? "service #{k[0]}, account #{k[1]}" : "service #{k}" }.join("; ")}."
  end

  def secret_service(entries = nil, locked: false, unreachable: false, **given)
    entries ||= given
    items = entries.map { |pairs, secret| { "attributes" => pairs.split.each_slice(2).to_h, "secret" => secret } }
    store_on_path "secret-tool", "FAKE_SECRET_TOOL", "locked" => locked, "unreachable" => unreachable, "items" => items
    note_situation "The secret service (a fake secret-tool on the PATH)#{" is locked and" if locked}#{" cannot be reached (no D-Bus session) and" if unreachable} holds: #{entries.empty? ? "nothing" : entries.keys.join("; ")}."
  end

  def unlock_command(line)
    @unlock_env = { "FARMY_UNLOCK_COMMAND" => line }
    note_situation "FARMY_UNLOCK_COMMAND is: #{line}"
  end

  def assert_store_asked(text, times: nil)
    calls = store_calls
    hits = calls.select { |c| c.include?(text) }
    seen = calls.empty? ? "it was not asked anything" : "it was asked:\n    #{calls.join("\n    ")}"
    if times
      assert hits.size == times, "Expected the store on the PATH to have been asked #{text.inspect} #{times} time#{"s" unless times == 1}; #{seen}.#{transcript}"
    else
      assert !hits.empty?, "Expected the store on the PATH to have been asked #{text.inspect}; #{seen}.#{transcript}"
    end
  end

  def assert_passed_to_farmy(line)
    given = lines_passed_to_farmy
    assert given.include?(line), "Expected the shim to pass the line #{line} to farmy in the control container on stdin (docker exec -i farmy farmy …); #{given.empty? ? "it passed no line" : "it passed: #{given.map { |l| l.sub(/=.*/, "=…") }.join(", ")}"}.\n\n#{docker_situation}#{transcript}"
  end

  def refute_passed_to_farmy(name)
    given = lines_passed_to_farmy.select { |l| l.start_with?("#{name}=") }
    assert given.empty?, "Expected no line for #{name} to reach farmy in the control container on stdin; the shim passed #{given.map { |l| l.sub(/=.*/, "=…") }.join(", ")}.\n\n#{docker_situation}#{transcript}"
  end

  # What the shim passed to farmy on stdin, as it passed it (to hand to farmy in a test).
  def stdin_passed_to_farmy
    e = docker_state["execs"].reverse.find { |x| x["container"] == "farmy" && x["stdin"] && !x["stdin"].empty? }
    e ? e["stdin"] : flunk("Expected the shim to pass something to farmy on stdin; it passed nothing.\n\n#{docker_situation}#{transcript}")
  end

  # The value of NAME the shim passed to farmy, decoded, byte for byte.
  def value_passed_to_farmy(name)
    line = lines_passed_to_farmy.reverse.find { |l| l.start_with?("#{name}=") } or flunk("Expected the shim to pass #{name} to farmy; it did not.\n\n#{docker_situation}#{transcript}")
    raw = docker_state["execs"].select { |e| e["container"] == "farmy" && e["stdin"] }.flat_map { |e| e["stdin"].lines(chomp: true) }.reverse.find { |l| l.start_with?("#{name}:base64=", "#{name}=") }
    raw.start_with?("#{name}:base64=") ? raw.split("=", 2).last.unpack1("m").force_encoding("UTF-8") : line.split("=", 2).last
  end

  # A guide the work folder ships (docs/<name>.md) holds every one of these phrases.
  def assert_guide_says(path, *phrases)
    text = work_file(path)
    missing = phrases.reject { |p| text.include?(p) }
    assert missing.empty?, "Expected the guide #{path} to say each of these, and it does not: #{missing.map(&:inspect).join(", ")}."
  end

  # A file in the work folder: a guide, a shipped example.
  def work_file(name)
    File.read(File.join(Target.root, name))
  rescue Errno::ENOENT
    flunk "Expected #{name} in the work folder, and there is none."
  end

  # The folder put first on the PATH for every command: it holds the store a test chose, and nothing else.
  def store_bin = File.join(scratch, "stores").tap { |d| FileUtils.mkdir_p(d) }

  def store_env = (@store_env || {}).merge(@unlock_env || {})

  private

  def store_on_path(tool, prefix, state)
    FileUtils.ln_sf File.join(STORES, tool), File.join(store_bin, tool)
    File.write(File.join(scratch, "#{tool}.json"), JSON.generate(state))
    (@store_env ||= {}).merge!("#{prefix}_STORE" => File.join(scratch, "#{tool}.json"), "#{prefix}_LOG" => File.join(scratch, "#{tool}.log"))
  end

  def store_calls
    %w[security secret-tool].flat_map do |tool|
      log = File.join(scratch, "#{tool}.log")
      File.exist?(log) ? File.readlines(log, chomp: true).map { |l| "#{tool} #{l}" } : []
    end
  end

  # The lines the shim passed to farmy, an encoded NAME:base64=… line read as the NAME=value it carries.
  def lines_passed_to_farmy
    raw = docker_state["execs"].select { |e| e["container"] == "farmy" && e["stdin"] }.flat_map { |e| e["stdin"].lines(chomp: true) }
    raw.map { |l| l =~ /\A([A-Za-z_][A-Za-z0-9_]*):base64=(.*)\z/ ? "#{$1}=#{$2.unpack1("m").force_encoding("UTF-8")}" : l }
  end
end
