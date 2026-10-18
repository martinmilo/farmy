class GitContainersTest < AcceptanceTest
  test "service clone factory Git Dockerfile fetch and dotfiles clone and pull all receive the same SSH route and mesh plumbing" do
    git_containers_behind_mesh

    start_services_through_git_containers
    run_factory_through_git_containers
    pull_dotfiles_through_git_container

    assert_every_git_container_has_mesh_plumbing
  end
end
