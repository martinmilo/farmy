class ControlSourceCacheTest < AcceptanceTest
  def setup = workspace("workshop")

  test "normal init reuses the control image and container when local source is unchanged" do
    built_local_control

    normal_local_init

    assert_success
    assert_control_reused
  end

  MiniRegressions::CONTROL_CONTEXT_INPUTS.each do |path|
    test "normal init rebuilds and replaces control after #{path} changes at the same version without FARMY_BUILD" do
      built_local_control
      change_control_input path

      normal_local_init

      assert_success
      assert_control_rebuilt
    end
  end

  %i[addition deletion mode symlink type].each do |change|
    test "normal init rebuilds control after a build input #{change} without changing its release version" do
      built_local_control
      mutate_control_input change

      normal_local_init

      assert_success
      assert_control_rebuilt
    end
  end
end
