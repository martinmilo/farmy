# The knowledge container's server as a program: bin/farmy-knowledge of the work folder, started by a test on
# a folder of the test's own (what farmy mounts at /kb). Torn down after the test.
#
#   start_knowledge "README.md" => "# farmy\n…", "docs/credentials.md" => "…", "status/status.tsv" => "…"
#   knowledge_call "status"                       → the text the tool answered
#   knowledge_call "read_doc", "name" => "docs/credentials.md"
#   knowledge_tools                               → the tool names tools/list answers
require "net/http"
require "json"
require "fileutils"

module Knowledge
  def start_knowledge(**files)
    kb = File.join(scratch, "kb")
    files.each do |path, content|
      full = File.join(kb, path.to_s)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end
    @knowledge_port = free_port
    exe = Target.path("bin/farmy-knowledge")
    raise Minitest::Assertion, "The tests run bin/farmy-knowledge in the work folder, and nothing executable is there." unless File.executable?(exe)
    @knowledge = Process.spawn({ "KB_DIR" => kb, "PORT" => @knowledge_port.to_s }, exe, out: File.join(scratch, "knowledge.out"), err: File.join(scratch, "knowledge.err"))
    deadline = Time.now + 10
    until knowledge_up?
      raise Minitest::Assertion, "bin/farmy-knowledge did not answer /-/health within 10 s.\n#{File.read(File.join(scratch, "knowledge.err"))}" if Time.now > deadline
      sleep 0.1
    end
    note_situation "The knowledge server runs on a folder holding: #{files.keys.join(", ")}."
  end

  def knowledge_rpc(method, params = {})
    http = Net::HTTP.new("127.0.0.1", @knowledge_port)
    response = http.post("/mcp", JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params), "Content-Type" => "application/json")
    assert_equal "200", response.code, "Expected the knowledge server to answer #{method} with 200, got #{response.code}: #{response.body}"
    JSON.parse(response.body)
  end

  def knowledge_tools = knowledge_rpc("tools/list").dig("result", "tools").map { |t| t["name"] }

  def knowledge_call(name, arguments = {})
    answer = knowledge_rpc("tools/call", "name" => name, "arguments" => arguments)
    answer.dig("result", "content", 0, "text") or flunk("Expected a text answer from the tool #{name}, got: #{answer}")
  end

  def after_teardown
    super
    if @knowledge
      Process.kill("TERM", @knowledge) rescue nil
      Process.wait(@knowledge) rescue nil
    end
  end

  private

  def knowledge_up?
    Net::HTTP.get_response(URI("http://127.0.0.1:#{@knowledge_port}/-/health")).code == "200"
  rescue StandardError
    false
  end
end
