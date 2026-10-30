class GitContainersTest < AcceptanceTest
  test "service clone factory Git Dockerfile fetch and dotfiles clone and pull all receive the same SSH route and mesh plumbing" do
    git_containers_behind_mesh

    start_services_through_git_containers
    run_factory_through_git_containers
    pull_dotfiles_through_git_container

    assert_every_git_container_has_mesh_plumbing
  end
  test "build files fetched over an SSH git route are written into the state folder as the user farmy runs as, with no container writing them as root and chowning them afterwards" do
    git_containers_behind_mesh
    build_files_over_ssh
    git_transport_phase "dockerfile-fetch"

    farmy "start", "toolkit", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"

    assert_success
    assert_built target: "base", files: ["Dockerfile"]
    assert_build_files_fetched_as invoking_user
  end

  test "over an SSH git route too, a build file that is a link to ../.env stops the start, naming it, and nothing of the containers folder's .env reaches a build context" do
    git_containers_behind_mesh
    build_files_over_ssh build_files: ["Gemfile.lock"]
    the_folder_env_also_holds "DEPLOY_TOKEN=dpl_7c41e9a2"
    remote_repository_link "acme/toolkit", "Gemfile.lock" => "../.env"

    farmy "start", "toolkit", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"

    assert_exit 1
    assert_stderr "Gemfile.lock"
    assert_stderr "outside the repository"
    refute_in_any_build_context "dpl_7c41e9a2"
  end
end

