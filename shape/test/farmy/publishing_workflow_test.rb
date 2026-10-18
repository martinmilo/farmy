class PublishingWorkflowTest < AcceptanceTest
  test "the real release workflow runs for v star tags and builds all four images on both native architectures" do
    assert_includes Array(workflow_events(release_workflow).dig("push", "tags")), "v*"
    assert_native_release_matrix
  end

  test "native build and manifest jobs use GITHUB_TOKEN with packages write while release assets can write contents" do
    assert_release_token_permissions
  end

  test "all eight distinct native build digests must be available before any manifest publishes" do
    assert_digest_handoffs
  end

  test "version and latest manifests gate publication of the installer and its SHA256SUMS release asset" do
    assert_release_assets_order
  end

  test "the optional opened PR notice requires explicit enablement and only comment permissions" do
    assert_optional_notice
  end

  test "the PR notice explains proposal application delivery and credit without executing or merging proposal code" do
    assert_notice_policy_without_proposal_execution
  end
end
