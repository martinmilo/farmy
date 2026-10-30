# One maker of the control container at a time (record 2026-10-29-1800). Two terminals that find no control container
# must not both make it: one would remove the other's new container, or fail on Docker's name conflict. The shim holds a
# lock in the state home while it reads the control container and makes or reuses it; a second shim waits, then reuses.
class ShimControlLockTest < AcceptanceTest
  def setup = workspace("workshop") # no control container yet

  test "two terminals running farmy at the same moment with no control container make it once: the second waits for the first, then runs its command in the container the first made" do
    control_container_made_slowly

    two_terminals_at_once "status"

    assert_both_terminals_succeeded
    assert_control_container_made_once
    assert_ran_in_control_container_times "farmy status", 2
  end

  test "a shim killed while making the control container leaves no lock that holds up the next command: it makes the container and runs" do
    control_container_made_slowly
    a_shim_killed_while_making_the_control_container

    shim "status"

    assert_success
    assert_ran_in "farmy", "farmy status"
  end
end
