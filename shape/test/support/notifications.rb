# Notifications cross a real HTTP boundary. The fake receiver records requests; the public
# factory commands supply events, and status/show expose their recorded run outcome.
module Notifications
  def notifying_factory(format: "json", receiver_status: 200, receiver_body: "accepted", private_endpoint: false, compare: true, **options)
    @notification_receiver = fake_upstream(status: receiver_status, body: receiver_body)
    @notification_url = "#{@notification_receiver.url}/farmy-events"
    @notification_url += "?key=notify-private-endpoint-7e42" if private_endpoint
    notify = { "format" => format }
    config = { "notify" => notify }
    if private_endpoint
      notify.merge!("url_secret" => "NOTIFY_URL", "token_secret" => "NOTIFY_TOKEN")
      config["secrets"] = { "provider" => ["bin/provider"] }
      secrets_provider NOTIFY_URL: @notification_url, NOTIFY_TOKEN: "notify-private-token-4ac8"
    else
      notify["url"] = @notification_url
    end
    profiled_factory(**options, extra_config: YAML.dump(config).delete_prefix("---\n"))
    if compare
      definition = YAML.safe_load(read_file("services/shop.yml"))
      definition.merge!("forge" => "github", "repo_web_url" => "https://github.com/acme/shop")
      write_file "services/shop.yml", YAML.dump(definition)
    end
    note_situation "notify uses #{format} POSTs to the local receiver; it answers HTTP #{receiver_status}. #{private_endpoint ? 'Its endpoint and bearer token are provider secrets NOTIFY_URL and NOTIFY_TOKEN.' : 'Its endpoint is a public literal URL.'}"
  end

  def notification_requests
    @notification_receiver.requests
  end

  def notification_pipeline
    change_factory_definition do |definition|
      definition["pipelines"] = { "build" => { "steps" => %w[shape work], "on_question" => "shape" } }
    end
  end

  def assert_notification(event, result: event, profile: "work", compare: true, pipeline_id: nil, step: nil)
    request, payload = json_notification(event)
    assert_equal "POST", request["method"], "Expected notification delivery by HTTP POST.#{transcript}"
    assert_match %r{\Aapplication/json(?:;|\z)}, request.dig("headers", "content-type").to_s,
                 "Expected JSON notification Content-Type application/json.#{transcript}"
    expected = { "event" => event, "result" => result, "service" => "shop", "profile" => profile,
                 "pipeline_id" => pipeline_id, "step" => step }
    expected.each do |key, value|
      assert payload.key?(key), "Expected notification JSON to include #{key}, including null for standalone pipeline/step fields.#{transcript}"
      message = "Expected notification #{key}=#{value.inspect}; got #{payload.inspect}.#{transcript}"
      value.nil? ? assert_nil(payload[key], message) : assert_equal(value, payload[key], message)
    end
    assert_match(/\A\d{8}-\d{6}-[0-9a-f]{4}\z/, payload["run_id"].to_s, "Expected the notification's run_id.#{transcript}")
    assert_equal "farmy/shop/#{payload['run_id']}", payload["branch"], "Expected the run's branch in its notification.#{transcript}"
    assert_match(/\A[0-9a-f]{40}\z/, payload["commit"].to_s, "Expected a pinned full commit SHA in its notification.#{transcript}")
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z\z/, payload["timestamp"].to_s,
                 "Expected the notification timestamp in RFC3339 UTC.#{transcript}")
    refute_empty payload["event_id"].to_s, "Expected a stable event_id in the notification.#{transcript}"
    if compare
      assert_match(%r{\Ahttps://github\.com/acme/shop/compare/[0-9a-f]{40}\.\.\.[0-9a-f]{40}\z}, payload["compare_url"].to_s,
                   "Expected a GitHub compare URL between pinned base and result commits.#{transcript}")
      assert payload["compare_url"].end_with?(payload["commit"]), "Expected the comparison to end at the notified commit.#{transcript}"
    else
      assert_nil payload["compare_url"], "Expected null compare_url for an unknown local forge, retaining the branch fallback.#{transcript}"
    end
    @last_notification = payload
  end

  def assert_notification_matches_public_review
    payload = @last_notification or flunk "First assert the awaiting_review notification."
    farmy "factory", "show", payload.fetch("run_id")
    assert_success
    assert_stdout payload.fetch("compare_url")
    farmy "status", "--json"
    assert_success
    assert_run_status payload.fetch("run_id"), result: "awaiting_review", compare_url: payload.fetch("compare_url")
  end

  def assert_notification_text(format, event:, profile: "work")
    wait_notification_requests 1
    request = notification_requests.last
    assert request, "Expected a #{format} notification received by HTTP POST; no request arrived.#{transcript}"
    assert_equal "POST", request["method"], "Expected a #{format} notification by HTTP POST.#{transcript}"
    text = if format == "slack"
      assert_match(%r{\Aapplication/json(?:;|\z)}, request.dig("headers", "content-type").to_s,
                   "Expected Slack-compatible webhook JSON.#{transcript}")
      JSON.parse(request.fetch("body")).fetch("text", "")
    else
      assert_match(%r{\Atext/plain(?:;|\z)}, request.dig("headers", "content-type").to_s,
                   "Expected ntfy's readable text POST.#{transcript}")
      request.fetch("body")
    end
    ["shop", profile, event].each { |part| assert_includes text, part, "Expected #{format} notification to identify #{part}.#{transcript}" }
    assert_match(/\d{8}-\d{6}-[0-9a-f]{4}/, text, "Expected the run ID in readable notification text.#{transcript}")
    assert_match(%r{farmy/shop/\d{8}-\d{6}-[0-9a-f]{4}}, text, "Expected the branch in readable notification text.#{transcript}")
    assert_match(%r{https://github\.com/acme/shop/compare/[0-9a-f]{40}\.\.\.[0-9a-f]{40}}, text,
                 "Expected a pinned review URL in readable notification text.#{transcript}")
  rescue JSON::ParserError
    flunk "Expected Slack-compatible JSON containing a text field.#{transcript}"
  end

  def assert_notification_attempts(count, event:)
    wait_notification_requests count
    matches = notification_requests.filter_map do |request|
      payload = JSON.parse(request["body"]) rescue nil
      payload if payload && payload["event"] == event
    end
    assert_equal count, matches.length, "Expected exactly #{count} HTTP delivery attempts for #{event}; received #{notification_requests.length} request(s).#{transcript}"
    ids = matches.map { |payload| payload["event_id"] }.uniq
    assert_equal 1, ids.length, "Expected every retry to reuse one persisted event_id.#{transcript}"
    refute_empty ids.first.to_s, "Expected the event_id to be nonempty on every retry.#{transcript}"
  end

  def assert_notification_authorization
    wait_notification_requests 1
    request = notification_requests.last
    assert request, "Expected a notification request resolved through provider references NOTIFY_URL and NOTIFY_TOKEN.#{transcript}"
    assert_equal "/farmy-events?key=notify-private-endpoint-7e42", request["path"], "Expected the provider's endpoint to receive the notification.#{transcript}"
    assert_equal "Bearer notify-private-token-4ac8", request.dig("headers", "authorization"), "Expected the provider's token only in the outgoing Authorization header.#{transcript}"
  end

  def refute_notification_credentials_persisted
    refute_secret_anywhere @notification_url
    refute_secret_anywhere "notify-private-endpoint-7e42"
    refute_secret_anywhere "notify-private-token-4ac8"
    assert_file "farmy.yml", includes: "url_secret: NOTIFY_URL"
    assert_file "farmy.yml", includes: "token_secret: NOTIFY_TOKEN"
  end

  def refute_notification_error_details
    [@notification_url, "notify-private-endpoint-7e42", "notify-private-token-4ac8", "receiver-private-body-9b31", "Authorization"].each do |part|
      refute_stdout part
      refute_stderr part
    end
  end

  def refute_notification_content(*parts)
    assert !notification_requests.empty?, "Expected at least one notification before checking its privacy.#{transcript}"
    notification_requests.each do |request|
      parts.each { |part| refute_includes request["body"], part, "Expected notification payloads to omit task, question, answer and agent/test-log content by default.#{transcript}" }
      payload = JSON.parse(request["body"]) rescue {}
      forbidden = payload.keys & %w[task question answer logs log stdout stderr prompt]
      assert_empty forbidden, "Expected notification payload identity fields only; found content fields #{forbidden.inspect}.#{transcript}"
    end
  end

  private

  def wait_notification_requests(count)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.02 until notification_requests.length >= count || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
  end

  def json_notification(event)
    wait_notification_requests 1
    pairs = notification_requests.filter_map do |request|
      payload = JSON.parse(request["body"]) rescue nil
      [request, payload] if payload && payload["event"] == event
    end
    assert !pairs.empty?, "Expected a JSON webhook event #{event.inspect} at the configured receiver; received #{notification_requests.length} request(s): #{notification_requests.map { |r| r['body'] }.inspect}.#{transcript}"
    pairs.last
  end
end
