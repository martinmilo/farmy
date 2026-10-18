require "minitest/autorun"

# Program output is read as UTF-8 whatever locale the machine happens to have.
Encoding.default_external = Encoding::UTF_8

# ── This project ─────────────────────────────────────────────────────────
PROGRAM = "bin/farmy" # the executable the tests run, relative to the work folder; ./setup writes it
# ─────────────────────────────────────────────────────────────────────────

TEST_ROOT = __dir__

Dir[File.join(TEST_ROOT, "support", "*.rb")].sort.each { |file| require file }

class AcceptanceTest < Minitest::Test
  # Pipeline contracts supersede the older factory pause/review helpers.
  include FactoryPipelines, Fixtures, ExactText, Workspace, Commands, Farmy, Broker, Knowledge, Unlock, Agents, Egress, EgressControl, Private, Stranger, Factory, FactoryProfiles, Distribution, AuditEgress, Notifications, EgressModes, ToolboxAndDotfiles, MiniRegressions, MiniPipelines, Publishing, PublishingWorkflows, GitContainers, ReleaseIdentity, HolderSocket, EntrypointExec, DotfilesMounts, FarmyEntrypoint

  def before_setup
    Processes.become_subreaper
    super
  end

  # Defined on the class, so it runs after every module's own teardown has stopped what it started.
  def after_teardown
    super
  ensure
    left = Processes.sweep
    unless left.empty?
      flunk "This test left #{left.size} process(es) running after its teardown; they were killed now:\n" \
            "#{Processes.summary(left)}\n" \
            "Whatever a test starts (farmy hold, a detached factory controller, a fake docker child, a server) " \
            "must have ended by the time the test does."
    end
  end

  # test "a redeemed voucher cannot be redeemed again" do ... end
  def self.test(sentence, &block)
    name = "test_#{sentence.gsub(/\W+/, "_")}"
    raise ArgumentError, "#{self} already has a test named: #{sentence}" if method_defined?(name)
    define_method(name, &block)
  end
end
