module GitContainers
  def git_containers_behind_mesh
    dotfiles_workspace
    private_dotfiles :ssh
    config = YAML.safe_load(read_file("farmy.yml"))
    config["dotfiles"]["repo"] = "https://git.example.com/dev/dotfiles.git"
    config["secrets"]["unlock"] = ["TS_AUTHKEY"]
    config["egress"] = { "authkey" => "TS_AUTHKEY" }
    config["keys"]["anthropic"] = { "secret" => "ANTHROPIC_API_KEY", "upstream" => "https://api.anthropic.com", "auth" => "header", "header" => "x-api-key" }
    write_file "farmy.yml", YAML.dump(config)
    secrets_provider GIT_SSH_KEY: fixture("keys/git_ed25519"), ANTHROPIC_API_KEY: "sk-ant-api03-4f9e"
    remote_repository "acme/shop", "src/app.txt" => "broken\n", "test/check.sh" => "grep -q fixed src/app.txt\n"
    write_file "services/shop.yml", YAML.dump({ "repo" => remote_url("acme/shop"), "image" => "debian:bookworm-slim",
      "commands" => { "test" => "sh test/check.sh" },
      "factory" => { "base" => "main", "agent" => "claude", "writes" => ["src/"], "protects" => ["test/"], "test" => "test", "max_iterations" => 1 } })
    remote_repository "acme/toolkit", "Dockerfile" => "FROM debian:bookworm-slim AS base\nWORKDIR /workspace\n"
    write_file "services/toolkit.yml", YAML.dump({ "repo" => remote_url("acme/toolkit"), "dockerfile" => "Dockerfile", "target" => "base" })
    change_docker_state do |state|
      host = state.fetch("git_hosts").delete("ssh://git@git.example.com/dev/dotfiles.git")
      host["aliases"] = ["ssh://git@git.example.com/dev/dotfiles.git"]
      state["git_hosts"]["https://git.example.com/dev/dotfiles.git"] = host
      state["required_git_transport"] = true
    end
    note_situation "Every farmy-owned Git helper must join farmy and its broker network, carry mesh proxy variables and SSH ProxyCommand, mount the loaded SSH agent and rewrite HTTPS Git URLs to SSH. The HTTPS dotfiles host is reachable only through that complete SSH/mesh path; its accepted transport maps to a real bare repository."
  end

  def git_transport_phase(name)
    change_docker_state { |state| state["git_transport_phase"] = name }
  end

  def start_services_through_git_containers
    git_transport_phase "service-and-dotfiles-clone"
    farmy "start", "shop", stdin: "TS_AUTHKEY=tskey-auth-k9f2c1e5d7b\n"
    assert_success
    assert_shared_dotfiles_clone
    assert_dotfiles_authentication :ssh
    git_transport_phase "dockerfile-fetch"
    farmy "start", "toolkit"
    assert_success
    assert_built target: "base", files: ["Dockerfile"]
  end

  def run_factory_through_git_containers
    git_transport_phase "factory"
    agent_plays({ writes: { "src/app.txt" => "fixed\n" } })
    factory_start
    assert_success
    assert_stdout "green"
    assert_pushed "farmy/shop/#{run_id}", commits: ["farmy: iteration 1"]
  end

  def pull_dotfiles_through_git_container
    advance_dotfiles
    git_transport_phase "dotfiles-pull"
    farmy "dotfiles", "pull"
    assert_success
    assert_shared_dotfiles_clone
    assert_dotfile_link "shop", ".zshrc", content: "export FARMY_DOTFILES_ZSH=updated\n"
    assert_dotfile_link "toolkit", ".inputrc", content: "set editing-mode vi\n"
  end

  def assert_every_git_container_has_mesh_plumbing
    runs = docker_state.fetch("git_transport_observations", [])
    refute_empty runs, "Expected real Git commands behind the fake Docker boundary, not no-op container records.#{transcript}"
    {
      "service clone" => ["service-and-dotfiles-clone", "shop-src"],
      "dotfiles clone" => ["service-and-dotfiles-clone", "farmy-shared"],
      "Dockerfile fetch" => ["dockerfile-fetch", nil],
      "factory Git" => ["factory", nil],
      "dotfiles pull" => ["dotfiles-pull", "farmy-shared"]
    }.each do |operation, (phase, volume)|
      selected = runs.select { |run| run["phase"] == phase && (!volume || run.fetch("volumes", []).include?(volume)) }
      if operation == "Dockerfile fetch"
        selected = selected.select { |run| run.fetch("process", []).join(" ").match?(/\b(?:clone|fetch|archive)\b/) && (run.fetch("volumes", []) & %w[toolkit-src farmy-shared]).empty? }
      end
      refute_empty selected, "Expected #{operation} to start a Git container through the shared launcher; a direct control-process Git call or app-entrypoint clone is insufficient.#{transcript}"
    end
    runs.each { |run| assert_git_container_mesh_plumbing(run) }
    refute_secret_anywhere "AAAAC3NzaC1lZDI1NTE5AAAAIEjn"
  end

  def assert_git_container_mesh_plumbing(run)
    label = "#{run['phase']} #{run['name'] || run.dig('labels', 'farmy.role')}"
    env = run.fetch("env")
    assert_includes run.fetch("networks"), "farmy", "Expected #{label} on farmy before Git starts."
    assert run.fetch("broker_ready"), "Expected #{label} to reach its loaded route broker and mounted agent."
    %w[HTTP_PROXY HTTPS_PROXY http_proxy https_proxy].each do |key|
      assert_equal "http://farmy-egress:1055", env[key], "Expected #{label}'s #{key} to use mesh egress."
    end
    %w[ALL_PROXY all_proxy].each do |key|
      assert_equal "socks5h://farmy-egress:1055", env[key], "Expected #{label}'s #{key} to resolve the upstream through mesh."
    end
    %w[localhost 127.0.0.1 keys farmy-egress].each do |host|
      assert_includes env.fetch("NO_PROXY", "").split(","), host, "Expected #{label} to bypass the proxy for local #{host}."
    end
    assert_equal env["NO_PROXY"], env["no_proxy"], "Expected both NO_PROXY spellings in #{label}."
    config = env.select { |key, _| key.start_with?("GIT_CONFIG_KEY_") }.to_h { |key, value| [value, env["GIT_CONFIG_VALUE_#{key.delete_prefix('GIT_CONFIG_KEY_')}"]] }
    ssh = env["GIT_SSH_COMMAND"] || config["core.sshCommand"]
    assert_match(/ProxyCommand=.*nc .*?-X 5 .*?-x farmy-egress:1055 .*?%h .*?%p/, ssh.to_s, "Expected #{label} to send SSH and upstream DNS through mesh.")
    assert_equal "https://git.example.com/", config["url.ssh://git@git.example.com/.insteadOf"], "Expected #{label}'s HTTPS-to-SSH rewrite for subsequent Git operations."
    assert_equal "/run/farmy-keys/agent.sock", env["SSH_AUTH_SOCK"], "Expected #{label} to use the broker agent socket."
    assert run.fetch("mounts").any? { |mount| mount["target"] == "/run/farmy-keys" && mount["name"].end_with?("-keys-agent") }, "Expected #{label} to mount the broker agent volume."
    refute env.key?("GIT_SSH_KEY"), "Expected #{label} to receive an agent socket, never private-key bytes."
  end
end
