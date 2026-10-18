class ReleaseTest < AcceptanceTest
  test "release publishes all four images for amd64 and arm64 with version latest and metadata in the chosen registry" do
    release_distribution

    assert_success
    assert_release_builds "0.1.0"
  end

  test "release accepts a self-hosted registry with a port instead of a built-in registry" do
    release_distribution registry: "forgejo.example.com:3000/ops"

    assert_success
    assert_release_builds "0.1.0", registry: "forgejo.example.com:3000/ops"
  end

  test "release without FARMY_REGISTRY publishes to the configured default GHCR namespace" do
    release_distribution registry: ""

    assert_success
    assert_default_release_builds "0.1.0"
  end

  ["0.x", "v0.1.0", "0.1.0;touch marker", "0.2.0"].each do |version|
    test "release version #{version} is refused because it is invalid or differs from repository VERSION" do
      release_distribution version

      assert_exit 1
      assert_stderr(/version/i)
      refute_release_builds
      refute_file "marker"
    end
  end

  test "a buildx failure fails release without claiming it was published" do
    buildx_fails

    release_distribution

    assert_failure
    assert_stderr(/buildx|builder/i)
    refute_stdout(/release.*published|published.*release/i)
  end

  test "exporting the gate image builds both platforms to an OCI archive without a registry or push" do
    export_gate_image

    assert_success
    assert_gate_export
  end

  test "an unknown release image role is refused before a build" do
    export_gate_image role: "missing"

    assert_exit 1
    assert_stderr "missing"
    refute_release_builds
  end
end

class DistributionIntegrationTest < AcceptanceTest
  test "real buildx exports the farmy gate image for both architectures when the builder is available" do
    real_multi_platform_build
  end
end
