module AuditEgress
  def nested_restriction(value)
    data = YAML.safe_load(read_file("services/shop.yml"))
    (data["egress"] ||= {})["restrict"] = value
    write_file "services/shop.yml", YAML.dump(data)
  end

  def assert_egress_events(count, event:, host: nil, container: nil)
    rows = stdout.lines.map { |line| JSON.parse(line) }
    selected = rows.select { |row| row["event"] == event && (!host || row["host"] == host) && (!container || row["container"] == container) }
    assert_equal count, selected.size, "Expected #{count} #{event} events for host=#{host.inspect}, container=#{container.inspect}; got #{rows.inspect}.#{transcript}"
    selected.each do |row|
      assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z\z/, row["timestamp"].to_s, "Expected RFC3339 UTC timestamp.#{transcript}")
      assert_equal "audit", row["mode"], "Expected allowed observation to identify audit mode.#{transcript}" if event == "allowed"
    end
  rescue JSON::ParserError
    flunk "Expected egress log --json to emit NDJSON events.#{transcript}"
  end

  def assert_readable_event(host:, decision:, service: "shop", container: "shop")
    line = stdout.lines.find { |l| l.include?(host) }
    assert line, "Expected a readable egress line for #{host}.#{transcript}"
    assert_match(/\A\d{4}-\d\d-\d\dT\S+Z\s+#{Regexp.escape(service)}\s+#{Regexp.escape(container)}\s+#{Regexp.escape(host)}\s+#{decision}\s*\z/, line,
                 "Expected time, service, container, host:port, decision in that order.#{transcript}")
  end

  def assert_filter_observations(count, host:)
    out, status = filter_control "log"
    assert status.success?, "Expected gate log to succeed: #{out}"
    rows = out.lines.map { |line| JSON.parse(line) }.select { |r| r["event"] == "allowed" && r["host"] == host }
    assert_equal count, rows.size, "Expected #{count} first-destination audit observations for #{host}; got #{out}."
    rows.each do |row|
      assert_equal "audit", row["mode"]
      assert_match(/\A\d{4}-\d\d-\d\dT.*Z\z/, row["timestamp"].to_s)
    end
  end
end
