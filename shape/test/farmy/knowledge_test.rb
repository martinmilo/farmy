class KnowledgeTest < AcceptanceTest
  # bin/farmy-knowledge as a program, on a folder of the test's own: what the agents inside the containers can ask.

  README = "# farmy\n\nOne set of containers per repository.\n\n## Adding a service\n\nWrite services/<name>.yml with repo: and image:.\n".freeze
  CREDENTIALS = "# Credentials\n\nSecrets live in the keys broker next to the app container.\n".freeze
  SNAPSHOT = "generated\t2026-10-13T10:00:00Z\nservice\tshop\trunning\thttp://localhost:3100\tshop shop-keys shop-pg\nservice\tnotes\tstopped\t\t\nproblem\tnotes\tclone failed\n".freeze

  test "the knowledge server lists its five read-only tools" do
    start_knowledge "README.md" => README

    assert_equal %w[list_docs read_doc search_docs service status], knowledge_tools.sort
  end

  test "status reads the snapshot farmy wrote and tells the agent to refresh it with farmy status" do
    start_knowledge "README.md" => README, "status/status.tsv" => SNAPSHOT

    text = knowledge_call "status"

    assert_includes text, "shop: running"
    assert_includes text, "http://localhost:3100"
    assert_includes text, "notes: stopped"
    assert_includes text, "clone failed"
    assert_includes text, "farmy status"
  end

  test "status without a snapshot says so and names the command that writes one" do
    start_knowledge "README.md" => README

    assert_includes knowledge_call("status"), "farmy status"
  end

  test "search_docs answers with file and line, and read_doc with the document" do
    start_knowledge "README.md" => README, "docs/credentials.md" => CREDENTIALS, "services/shop.yml" => "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nports: [\"3100:3000\"]\n"

    assert_includes knowledge_call("search_docs", "query" => "KEYS BROKER"), "docs/credentials.md:3:"
    assert_equal CREDENTIALS, knowledge_call("read_doc", "name" => "docs/credentials.md")
    assert_includes knowledge_call("service", "name" => "shop"), "ports: [\"3100:3000\"]"
  end
end
