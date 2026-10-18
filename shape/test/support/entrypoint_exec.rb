# Commands that exec into a running app container and run its entrypoint in a mode
# (farmy-entrypoint --git-config, --home, …), as `farmy dotfiles pull` does.
#
#   image_built_by_older_farmy "shop"     shop's image carries an older build hash and an entrypoint from before
#                                         entrypoint modes: it ignores the mode and never returns
#   refute_entrypoint_mode_run "shop", "--git-config"   since the last command began, no exec ran it
#   refute_left_running "sleep 600"       no such process is still running anywhere below the test
module EntrypointExec
  OLDER_HASH = "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567"

  def image_built_by_older_farmy(service)
    tag = "farmy/#{service}:dev"
    change_docker_state do |state|
      image = state["images"][tag] or raise "no image #{tag} in the fake's state; start #{service} first"
      texts = image["file_texts"] ||= {}
      raise "the image #{tag} has no entrypoint.sh in its build context" unless texts.key?("entrypoint.sh")
      texts["entrypoint.sh"] = fixture("farmy/old-entrypoint.sh")
      image["labels"] = (image["labels"] || {}).reject { |key, _| key.start_with?("farmy.") && !%w[farmy.version farmy.hash].include?(key) }
      image["labels"]["farmy.hash"] = OLDER_HASH
    end
    @mode_execs_before = docker_state["execs"].size
    note_situation "#{service}'s image was built by an older farmy (farmy.hash #{OLDER_HASH}): its entrypoint knows no modes, " \
                   "and given one it starts normally and ends in exec tail -f /dev/null."
  end

  def refute_entrypoint_mode_run(service, mode)
    since = @mode_execs_before || 0
    runs = docker_state["execs"].drop(since).select { |e| e["container"] == service && e["command"].any? { |w| w.include?("farmy-entrypoint") } && e["command"].include?(mode) }
    assert_empty runs, "Expected no exec into #{service} running its entrypoint with #{mode}: its image cannot handle the mode, so the exec would never return. " \
                       "It ran: #{runs.map { |e| e["command"].join(" ") }.join(" | ")}.#{transcript}"
  end

  # Since the image was aged, no exec ran the container's entrypoint with any --mode at all: an older
  # entrypoint ignores the mode and does a normal startup, which once wrote git settings to ~/.gitconfig.
  def refute_any_entrypoint_mode_run(service)
    since = @mode_execs_before || 0
    runs = docker_state["execs"].drop(since).select do |e|
      e["container"] == service && e["command"].any? { |w| w.include?("farmy-entrypoint") } && e["command"].any? { |w| w.start_with?("--") }
    end
    assert_empty runs, "Expected no exec into #{service} running its entrypoint with any mode: its image was built by an older farmy, whose " \
                       "entrypoint ignores modes, starts normally and writes git settings to the user's global config. It ran: " \
                       "#{runs.map { |e| e["command"].join(" ") }.join(" | ")}.#{transcript}"
  end

  def refute_left_running(text)
    left = Processes.descendants.reject { |_, state| state == "Z" }.map(&:last).select { |line| line.include?(text) }
    assert_empty left, "Expected nothing running #{text.inspect} once the command had ended (a timed-out exec must be stopped inside the container too); still running: #{left.join(" | ")}.#{transcript}"
  end
end
