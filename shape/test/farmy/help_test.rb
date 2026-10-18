class HelpTest < AcceptanceTest
  test "farmy with no arguments prints the usage with every command" do
    farmy

    assert_success
    %w[init add start stop restart rebuild destroy status url run keys logs ssh session update help].each { |command| assert_stdout(/^\s+#{command}\b/) }
  end

  test "the usage says that keys reload exists" do
    farmy

    assert_stdout(/^\s+keys reload\b/)
  end

test "the usage says that status --json exists" do
  farmy

  assert_stdout(/^\s+status\b.*--json/)
end

  test "farmy help prints the usage" do
    farmy "help"

    assert_success
    assert_stdout(/^\s+start\b/)
  end

  test "an unknown command is refused and farmy help is pointed at" do
    farmy "deploy"

    assert_exit 2
    assert_stderr "unknown command 'deploy'"
    assert_stderr "farmy help"
  end

  %w[up down login secrets].each do |old|
    test "the copied program's command #{old} is unknown" do
      farmy old

      assert_exit 2
      assert_stderr "unknown command '#{old}'"
    end
  end

  test "the usage lists lock" do
    farmy "help"

    assert_stdout(/^\s+lock\b/)
  end

  test "the usage lists factory" do
    farmy "help"

    assert_stdout(/^\s+factory\b/)
  end
end
