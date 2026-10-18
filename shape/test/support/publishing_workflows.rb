module PublishingWorkflows
  def shipped_release_config
    YAML.safe_load(public_artifact("work/release.yml"))
  end

  def assert_declared_release_identity
    config = shipped_release_config
    refute_equal "your-owner", config["owner"], "Expected the owner's explicitly supplied public release owner."
    assert_match(/\A[a-zA-Z0-9][a-zA-Z0-9-]*\z/, config["owner"].to_s)
    refute_equal "farmy maintainers", config["maintainer_name"], "Expected the owner's explicitly supplied public maintainer name."
    refute_empty config["maintainer_name"].to_s
    assert_match(/\A(?:ID|\d+)\+[^@]+@users\.noreply\.github\.com\z/, config["maintainer_email"].to_s,
      "Expected the requested GitHub noreply identity; the owner fills the real numeric ID.")
    assert_equal "https://github.com/#{config.fetch('owner')}/farmy", config["github_url"]
    assert_equal "#{config.fetch('github_url')}/issues", config["issues_url"]
    assert_equal "#{config.fetch('github_url')}/pulls", config["contributions_url"]
    assert_equal "public", config["public_remote"]
    assert_match(/proposal/i, config["contribution_text"].to_s)
  end

  def default_public_registry = "ghcr.io/#{shipped_release_config.fetch('owner')}/farmy"

  def assert_default_images_pulled(*roles, version: "0.1.0")
    assert_pulled(*roles.map { |role| "#{default_public_registry}/farmy-#{role}:#{version}" })
  end

  def assert_default_release_builds(version)
    assert_release_builds version, registry: default_public_registry
  end

  def assert_default_local_control_built(version: "0.1.0")
    assert_local_control_built source: "#{shipped_release_config.fetch('github_url')}.git#v#{version}:work"
  end

  def assert_public_export_manifest
    entries = public_artifact("work/public-files.txt").lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
    required = %w[README.md CONTRIBUTING.md LICENSE bin/publish bin/scan-private bin/scan-history .github/workflows/release.yml .github/workflows/mirror-pr.yml
      shape/FORMATS.md shape/test/run.rb shape/spec/2026-10-15-example.md work/release.yml work/public-files.txt work/VERSION work/Dockerfile
      work/release.Dockerfile work/Cargo.toml work/Cargo.lock work/farmy work/bin/build work/bin/install work/bin/release work/crates/control/src/main.rs
      work/tools.yml work/agents.yml work/egress-hosts.yml work/factory-prompt.md work/keys.Dockerfile work/gate.Dockerfile work/knowledge.Dockerfile
      work/toolbox/entrypoint.sh work/providers/env work/releases/0.1.0.md]
    covers = ->(path) { entries.any? { |entry| path == entry || (entry.end_with?("/") && path.start_with?(entry)) } }
    required.each { |path| assert covers.call(path), "Expected the reviewed export allowlist to cover #{path}, including acceptance tests and spec records." }
    %w[.git/config .env work/target/debug/farmy work/bin/farmy work/.work/state.json notes/internal.md].each do |path|
      refute covers.call(path), "Expected the export allowlist to exclude private/generated #{path}."
    end
  end

  def default_published_distribution(version = "0.1.0")
    published_release version, registry: default_public_registry
  end

  def install_default_distribution
    default_published_distribution
    install_distribution version: "0.1.0", env: { "FARMY_REGISTRY" => "" }
    assert_success
  end

  def assert_installer_documentation
    text = public_artifact("README.md")
    github = Regexp.escape(shipped_release_config.fetch("github_url"))
    assert text.match?(%r{#{github}/releases/(?:download/v[^/\s]+|latest/download)/install}),
      "Expected the README to link the configured GitHub installer release asset."
    assert text.include?("SHA256SUMS"), "Expected README to name the SHA256SUMS release asset."
    assert text.match?(/sha256sum|shasum\s+-a\s+256/), "Expected README checksum verification for the attached installer."
  end

  def assert_contribution_policy(path)
    text = public_artifact(path).gsub(/\s+/, " ")
    config = shipped_release_config
    assert text.include?(config.fetch("issues_url")), "Expected #{path} to send issues to the internet-accessible GitHub tracker."
    assert text.include?(config.fetch("contributions_url")), "Expected #{path} to welcome GitHub proposal PRs."
    assert text.match?(/mirror/i), "Expected #{path} to explain the GitHub code mirror."
    assert text.match?(/proposal/i), "Expected #{path} to call GitHub PRs proposals."
    assert text.match?(/maintainer[\s\S]{0,180}(?:apply|applie)[\s\S]{0,180}source repository/i), "Expected #{path} to explain maintainer application in the source repository."
    assert text.match?(/next release/i), "Expected #{path} to promise next-release delivery."
    assert text.match?(/credit[\s\S]{0,140}(?:contributor[\s\S]{0,140}release notes|release notes)|contributor[\s\S]{0,140}credit[\s\S]{0,140}release notes/i), "Expected #{path} to promise contributor credit in release notes."
    refute text.match?(%r{https?://[^\s)]+(?:forgejo|forge\.example)[^\s)]*/(?:issues|pulls)}), "Expected no inaccessible Forgejo contribution intake."
  end

  def release_workflow
    @release_workflow ||= YAML.safe_load(public_artifact(".github/workflows/release.yml"), aliases: true)
  end

  def notice_workflow
    @notice_workflow ||= YAML.safe_load(public_artifact(".github/workflows/mirror-pr.yml"), aliases: true)
  end

  def workflow_events(workflow) = workflow["on"] || workflow[true] || {}
  def workflow_jobs(workflow = release_workflow) = workflow.fetch("jobs", {})
  def job_text(job)
    values = [job["env"]&.values]
    Array(job["steps"]).each { |step| values << [step["run"], step["with"]&.values, step["env"]&.values] }
    values.flatten.compact.join("\n")
  end

  def image_build_jobs
    result = workflow_jobs.select { |_, job| Array(job["steps"]).any? { |step| step["uses"].to_s.start_with?("docker/build-push-action@") } }
    refute_empty result, "Expected native image-build jobs in the shipped workflow using build-push-action with observable platforms and digest outputs."
    result
  end

  def manifest_jobs
    result = workflow_jobs.select { |_, job| job_text(job).include?("imagetools create") }
    refute_empty result, "Expected workflow jobs to assemble digest-based multi-architecture manifests with buildx imagetools create."
    result
  end

  def asset_jobs
    result = workflow_jobs.select { |_, job| job_text(job).include?("SHA256SUMS") && (job_text(job).match?(/gh release/) || Array(job["steps"]).any? { |step| step["uses"].to_s.match?(/action-gh-release/) }) }
    refute_empty result, "Expected a workflow job publishing install and SHA256SUMS as GitHub release assets."
    result
  end

  def matrix_rows(job)
    matrix = job.dig("strategy", "matrix") || {}
    dimensions = matrix.reject { |key, _| %w[include exclude].include?(key) }
    rows = dimensions.reduce([{}]) { |current, (key, values)| current.flat_map { |row| Array(values).map { |value| row.merge(key => value) } } }
    if dimensions.empty? && matrix.key?("include")
      rows = Array(matrix["include"]).map(&:dup)
    else
      extras = []
      Array(matrix["include"]).each do |addition|
        compatible = rows.select { |row| dimensions.keys.all? { |key| !addition.key?(key) || row[key] == addition[key] } }
        compatible.empty? ? extras << addition.dup : compatible.each { |row| row.merge!(addition) }
      end
      rows += extras
    end
    rows.reject { |row| Array(matrix["exclude"]).any? { |excluded| excluded.all? { |key, value| row[key] == value } } }
  end

  def expand_matrix(text, row)
    text.to_s.gsub(/\$\{\{\s*matrix\.([\w.-]+)\s*\}\}/) do |expression|
      keys = Regexp.last_match(1).split(".")
      keys.reduce(row) { |value, key| value.is_a?(Hash) ? value[key] : nil }&.to_s || expression
    end
  end

  def assert_native_release_matrix
    rows = image_build_jobs.flat_map do |_, job|
      build = job.fetch("steps").find { |step| step["uses"].to_s.start_with?("docker/build-push-action@") }
      matrix_rows(job).map do |row|
        role = row.values.flat_map { |value| value.is_a?(Hash) ? value.values : value }.map(&:to_s).find { |value| %w[control keys knowledge gate].include?(value) }
        [role, expand_matrix(build.dig("with", "platforms"), row), expand_matrix(job["runs-on"], row)]
      end
    end
    expected = %w[control keys knowledge gate].flat_map { |role| [[role, "linux/amd64", "ubuntu-24.04"], [role, "linux/arm64", "ubuntu-24.04-arm"]] }
    assert_equal expected.sort, rows.sort_by(&:to_s), "Expected each of four image roles built once natively on the matching amd64/arm64 runner."
  end

  def effective_permissions(workflow, job) = job["permissions"] || workflow["permissions"] || {}

  def assert_release_token_permissions
    (image_build_jobs.merge(manifest_jobs)).each do |id, job|
      permissions = effective_permissions(release_workflow, job)
      assert_equal "read", permissions["contents"], "Expected #{id} to read source without repository write permission."
      assert_equal "write", permissions["packages"], "Expected #{id} to push GHCR packages with packages: write."
      assert_match(/GITHUB_TOKEN|github\.token/, job_text(job), "Expected #{id} to authenticate with GITHUB_TOKEN.")
      assert_match(/ghcr\.io/, job_text(job), "Expected #{id} to authenticate to GHCR.")
    end
    asset_jobs.each do |id, job|
      assert_equal "write", effective_permissions(release_workflow, job)["contents"], "Expected #{id} to upload release assets with contents: write."
    end
  end

  def upstream_jobs(id, seen = [])
    return [] if seen.include?(id)
    needs = Array(workflow_jobs.fetch(id).fetch("needs", []))
    needs + needs.flat_map { |parent| upstream_jobs(parent, seen + [id]) }
  end

  def assert_digest_handoffs
    names = []
    image_build_jobs.each do |id, job|
      build = job.fetch("steps").find { |step| step["uses"].to_s.start_with?("docker/build-push-action@") }
      assert_match(/push-by-digest=true/, build.dig("with", "outputs").to_s, "Expected #{id} to push architecture-specific digests.")
      assert_match(/(?:push=true|true)/, [build.dig("with", "outputs"), build.dig("with", "push")].join(" "))
      upload = job.fetch("steps").find { |step| step["uses"].to_s.start_with?("actions/upload-artifact@") }
      assert upload, "Expected #{id} to export digest artifacts for the merge jobs."
      assert_match(/\.outputs\.digest/, job_text(job), "Expected the actual build digest in #{id}'s handoff.")
      names.concat(matrix_rows(job).map { |row| expand_matrix(upload.dig("with", "name"), row) })
    end
    assert_equal 8, names.uniq.length, "Expected a distinct digest artifact for every image role and architecture."
    manifest_jobs.each do |id, job|
      assert_empty image_build_jobs.keys - upstream_jobs(id), "Expected every native build to succeed before #{id}."
      refute_match(/always\(\)/, job["if"].to_s, "Expected no failed-build bypass before manifest publication.")
      assert Array(job["steps"]).any? { |step| step["uses"].to_s.start_with?("actions/download-artifact@") }, "Expected #{id} to consume saved build digests."
      assert_match(/sha256|digest/, job_text(job))
    end
  end

  def assert_release_assets_order
    manifest_jobs.each_value do |job|
      text = job_text(job)
      assert_match(/:latest/, text, "Expected latest tags on multi-architecture manifests.")
      assert_match(/(?:version|VERSION|ref_name|GITHUB_REF)/, text, "Expected version tags on multi-architecture manifests.")
    end
    asset_jobs.each do |id, job|
      assert_empty manifest_jobs.keys - upstream_jobs(id), "Expected every manifest job to succeed before release assets."
      refute_match(/always\(\)/, job["if"].to_s)
      text = job_text(job)
      assert_match(/sha256sum|shasum\s+-a\s+256/, text)
      attachments = Array(job["steps"]).filter_map do |step|
        if step["uses"].to_s.match?(/action-gh-release/)
          step.dig("with", "files")
        elsif step["run"].to_s.match?(/\bgh\s+release\s+(?:upload|create)\b/)
          step["run"]
        end
      end.join("\n")
      assert_match(%r{(?:^|[\s/'"])install(?:$|[\s'"])}, attachments, "Expected install among the files attached to the GitHub release, regardless of its generator.")
      assert_match(%r{(?:^|[\s/'"])SHA256SUMS(?:$|[\s'"])}, attachments, "Expected SHA256SUMS attached beside the exact installer it checks.")
      assert_match(/--notes-file|body_path/, text, "Expected release notes from a public maintained file so proposal contributors can be credited.")
      assert_match(/releases\//, text, "Expected the version's public work/releases notes to accompany the assets.")
    end
  end

  def assert_optional_notice
    assert_equal ["opened"], Array(workflow_events(notice_workflow).dig("pull_request_target", "types")), "Expected the optional notice to target each newly opened PR using trusted base context."
    jobs = workflow_jobs(notice_workflow)
    refute_empty jobs, "Expected a PR-comment job."
    jobs.each do |id, job|
      assert_match(/vars\.FARMY_PR_NOTICE\s*==\s*['"]true['"]/, job["if"].to_s, "Expected #{id} disabled unless FARMY_PR_NOTICE=true.")
      permissions = effective_permissions(notice_workflow, job)
      assert(permissions["pull-requests"] == "write" || permissions["issues"] == "write", "Expected permission to comment on proposal PRs.")
      refute_equal "write", permissions["contents"], "Expected the notice not to modify repository code."
    end
  end

  def assert_notice_policy_without_proposal_execution
    text = workflow_jobs(notice_workflow).values.map { |job| job_text(job) }.join("\n")
    %w[mirror proposal maintainer].each { |word| assert_match(/#{word}/i, text, "Expected the notice to explain #{word}.") }
    assert_match(/source repository/i, text)
    assert_match(/next release/i, text)
    assert_match(/credit/i, text)
    assert_match(/release notes/i, text)
    assert_match(/createComment|gh pr comment|\/comments/, text, "Expected the notice to send a PR comment when enabled.")
    serialized = notice_workflow.to_s
    refute_match(/pull_request\.head|pull_request\.body|pull_request\.title|refs\/pull\/.*head/, serialized, "Expected no execution or interpolation of untrusted proposal content.")
    refute_match(/actions\/checkout@/, serialized, "The notice needs no checkout of proposal code.")
    refute_match(/gh pr (?:merge|close)|pulls\.(?:merge|update)/, text, "Expected an explanatory notice, not an automatic PR merge or closure.")
  end
end
