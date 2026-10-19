# The README's install section: the one-line installer first, then the checksum-verified download from the
# same release; every release download URL in it follows the release's naming.
class ReadmeInstallTest < AcceptanceTest
  test "the README's install section leads with the one-line installer from the latest release, then the checksum-verified download from the same release, for macOS and Linux" do
    assert_readme_orders "curl -fsSL #{release_url}/latest/download/install | sh",
                         "#{release_url}/download/v", "SHA256SUMS", "shasum -a 256 --check SHA256SUMS",
                         "sha256sum --check SHA256SUMS", "sh ./install"
  end

  test "every release download URL in the README follows the release naming and names an asset the release workflow attaches" do
    assert_readme_release_urls_name_attached_assets
  end
end
