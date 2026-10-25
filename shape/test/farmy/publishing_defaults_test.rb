class PublishingDefaultsTest < AcceptanceTest
  def setup = workspace("workshop")

  test "release configuration declares the supplied public owner and maintainer with a replaceable GitHub noreply address" do
    assert_declared_release_identity
  end

  test "the public export allowlist includes work shape acceptance tests and spec records without build products" do
    assert_public_export_manifest
  end

  test "the installer without a registry override pulls the configured default GHCR control image" do
    default_published_distribution

    install_distribution version: SHIPPED, env: { "FARMY_REGISTRY" => "" }

    assert_success
    assert_default_images_pulled "control"
    assert_installed_only_shim
  end

  test "normal init without a registry override pulls the configured default GHCR control image" do
    default_published_distribution

    distribution_shim "init", env: { "FARMY_REGISTRY" => "" }

    assert_success
    assert_default_images_pulled "control"
    refute_control_build
  end

  test "service startup without a registry override pulls helper images from the same default GHCR namespace" do
    egress_apps
    default_published_distribution

    farmy "start", "shop", env: { "FARMY_BUILD" => "", "FARMY_REGISTRY" => "" }

    assert_success
    assert_default_images_pulled "keys", "knowledge", "gate"
  end

  test "update without a registry override obtains all four roles from the configured GHCR namespace" do
    install_default_distribution
    default_published_distribution "0.3.0"

    distribution_shim "update", env: { "FARMY_REGISTRY" => "" }

    assert_success
    assert_default_images_pulled "control", "keys", "knowledge", "gate", version: "0.3.0"
  end

  test "the README links the GitHub installer release asset and documents exact SHA256SUMS verification" do
    assert_installer_documentation
  end

  ["README.md", "CONTRIBUTING.md"].each do |path|
    test "#{path} directs issues and proposal PRs to GitHub and explains next release delivery and contributor credit" do
      assert_contribution_policy path
    end
  end
end
