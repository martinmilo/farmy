# Every agent's CLI runs as dev: the catalogue installs none into a home directory, and farmy's toolbox
# tries each agent's version line as dev once the agents are installed, so an install dev cannot run fails
# the build instead of the run. The build itself is real Docker's: AgentCliIntegrationTest.
class AgentCliAsDevTest < AcceptanceTest
  def setup = workspace("workshop") # shop: image ruby:3.4

  test "agents.tsv gives each agent its version line in a column after process" do
    write_file "farmy.yml", "agents:\n  codex: {}\n"

    farmy "start", "shop"

    assert_agent_built "shop", "codex", version: "codex --version"
  end

  test "farmy's toolbox build runs a step as dev after installing the agents, where each agent's version line is tried as the user who will run it" do
    write_file "farmy.yml", "agents:\n  codex: {}\n"

    farmy "start", "shop"

    assert_toolbox_runs_a_step_as_dev "shop"
  end

  test "no catalogue agent's install line runs as dev or names a home directory" do
    assert_catalogue_installs_outside_homes
  end

  test "farmy's toolbox build gives each agent's as-dev version check 30 s, so a version command that never answers fails the build instead of hanging it" do
    write_file "farmy.yml", "agents:\n  codex: {}\n"

    farmy "start", "shop"

    assert_toolbox_version_check_limited_to_30_s "shop"
  end

  test "no catalogue install line pipes a download into a shell: each downloads to a file and runs it, so a failed download fails the install step" do
    assert_catalogue_installs_download_then_run
  end

  test "every install line the factory guide shows, the Claude pin included, runs as root outside any home and downloads before it runs" do
    assert_guide_installs_keep_the_catalogue_rules "docs/factory.md"
  end
end
