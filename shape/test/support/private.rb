# The private denylist, named by PRIVATE_TERMS_FILE (no default anywhere): terms that must
# appear in no tracked file of the repository. The list lives outside the repository.
#
#   private_terms                 the terms, or nil when the list is absent
#   assert_no_private_term_in_repository   tracked contents and paths, using the shipped scanner's
#                                           exact configured public-identity exception policy
module Private
  def private_terms
    path = ENV["PRIVATE_TERMS_FILE"].to_s
    return nil if path.empty? || !File.file?(path)
    File.readlines(path, chomp: true).map(&:strip).reject { |t| t.empty? || t.start_with?("#") }.map(&:downcase).uniq
  end

  def assert_no_private_term_in_repository
    root = File.expand_path("..", Target.root)
    scanner = Target.path("../bin/scan-private")
    assert File.executable?(scanner), "Expected the shipped bin/scan-private privacy scanner."
    env = Workspace::GIT_ENV.merge("PRIVATE_TERMS_FILE" => ENV["PRIVATE_TERMS_FILE"].to_s)
    out, err, status = Open3.capture3(env, scanner, chdir: root)
    assert status.success?, "Expected tracked contents and paths to pass the same exact public-identity policy used for publication; scanner reported:\n#{out}#{err}"
  end
end
