class EgressCatalogueTest < AcceptanceTest
  {
    "claude" => ["api.anthropic.com:443", "claude.ai:443", "platform.claude.com:443"],
    "codex" => ["api.openai.com:443", "chatgpt.com:443", "auth.openai.com:443"],
    "gemini" => ["generativelanguage.googleapis.com:443", "cloudcode-pa.googleapis.com:443", "oauth2.googleapis.com:443", "accounts.google.com:443", "www.googleapis.com:443"],
    "opencode" => ["opencode.ai:443"],
    "cursor" => ["api2.cursor.sh:443", "api5.cursor.sh:443", "*.api5.cursor.sh:443", "authenticate.cursor.sh:443", "authenticator.cursor.sh:443", "prod.authentication.cursor.sh:443", "authentication.cursor.sh:443"],
    "copilot" => ["github.com:443", "api.github.com:443", "*.githubcopilot.com:443", "copilot-proxy.githubusercontent.com:443", "origin-tracker.githubusercontent.com:443"]
  }.each do |name, hosts|
    test "the #{name} catalogue entry declares its verified API and authentication hosts on port 443" do
      assert_catalogue_api_hosts name, *hosts
    end
  end

  test "the shipped registries named set contains the requested package and download hosts" do
    assert_registry_hosts "deb.debian.org", "security.debian.org", "dl-cdn.alpinelinux.org", "rubygems.org", "index.rubygems.org",
                          "registry.npmjs.org", "pypi.org", "files.pythonhosted.org", "proxy.golang.org",
                          "crates.io", "index.crates.io", "static.crates.io"
  end
end
