# The repository is public: no tracked file holds a term of the owner's private denylist, which lives
# outside the repository. Without the list the test skips, loudly.
class NothingPrivateTest < AcceptanceTest
  test "no tracked file holds a term of the private denylist" do
    terms = private_terms
    skip warn_missing_terms unless terms

    assert_no_private_term_in_repository
  end

  private

  def warn_missing_terms
    message = "PRIVATE_TERMS_FILE is unset or names no file: nothing was checked for private terms"
    $stderr.puts "\n!! #{message}\n"
    message
  end
end
