class RepositoryTest < AcceptanceTest
  def setup = workspace("workshop") # shop: repo: https://github.com/acme/shop.git; notes: https://codeberg.org/acme/notes.git

  test "a definition names its repository by a full clone URL and status shows it" do
    farmy "status"

    assert_stdout(/^shop\s.*https:\/\/github\.com\/acme\/shop\.git/)
    assert_stdout(/^notes\s.*https:\/\/codeberg\.org\/acme\/notes\.git/)
  end

  test "a definition without repo is refused naming repo:" do
    write_file "services/toolkit.yml", "dockerfile: Dockerfile\ntarget: base\n"

    farmy "start", "toolkit"

    assert_exit 1
    assert_stderr "services/toolkit.yml"
    assert_stderr "repo:"
    refute_container "toolkit"
  end

  test "a repo that is not a clone URL is refused naming it" do
    write_file "services/shop.yml", "repo: acme/shop\nimage: ruby:3.4\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "services/shop.yml"
    assert_stderr "acme/shop"
    assert_stderr "clone URL"
    refute_container "shop"
  end

  test "the app container gets the clone URL as REPO" do
    farmy "start", "shop"

    assert_env "shop", "REPO", "https://github.com/acme/shop.git"
  end
end
