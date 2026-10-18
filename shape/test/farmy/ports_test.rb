class PortsTest < AcceptanceTest
  def setup = workspace("workshop") # shop: ports ["3100:3000"]; notes: ["3200:5173", "3201:24678"], uses ${url:shop}; toolkit: ["3300:3000"]

  test "a service's ports become its block, and ${FARMY_PORT_n} in its fragment is the n-th port of it" do
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nports: [\"3100:3000\"]\ncompose:\n  postgres:\n    image: postgres:18\n    container_name: shop-pg\n    ports: [\"127.0.0.1:${FARMY_PORT_32}:5432\"]\n"

    farmy "start", "shop"

    assert_publishes "shop", "3100:3000"
    assert_publishes "shop-pg", "3132:5432"
  end

  test "a definition without ports publishes nothing, and url prints nothing" do
    write_file "services/toolkit.yml", "repo: https://github.com/acme/toolkit.git\nimage: ruby:3.4\n"
    farmy "start", "toolkit"
    assert_success
    assert_publishes_nothing "toolkit"

    farmy "url", "toolkit"

    assert_success
    assert_stdout_lines 0
  end

test "starting a service without ports says that nothing is published" do
  write_file "services/toolkit.yml", "repo: https://github.com/acme/toolkit.git\nimage: ruby:3.4\n"

  farmy "start", "toolkit"

  assert_success
  assert_stdout "toolkit: no ports published"
end

  test "a service referred to with ${url:x} and without ports is given the next free block, written into its definition" do
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\n" # notes: VITE_API_URL: ${url:shop}; 3200 and 3300 are taken

    farmy "start", "notes"

    assert_success
    assert_stderr "services/shop.yml"
    assert_file "services/shop.yml", includes: "ports: [\"3100:3000\"]"
    assert_env "notes", "VITE_API_URL", "http://localhost:3100"
    assert_publishes "shop", "3100:3000"
  end

  test "a service whose own fragment uses ${FARMY_PORT_n} and has no ports is given a block the same way" do
    write_file "services/toolkit.yml", "repo: https://github.com/acme/toolkit.git\nimage: ruby:3.4\ncompose:\n  postgres:\n    image: postgres:18\n    container_name: toolkit-pg\n    ports: [\"127.0.0.1:${FARMY_PORT_32}:5432\"]\n" # 3100 and 3200 are taken

    farmy "start", "toolkit"

    assert_success
    assert_file "services/toolkit.yml", includes: "ports: [\"3300:3000\"]"
    assert_publishes "toolkit-pg", "3332:5432"
  end

  test "two services whose host ports lie in the same block are refused naming the block" do
    write_file "services/notes.yml", "repo: https://codeberg.org/acme/notes.git\nimage: node:22\nports: [\"3150:5173\"]\n" # shop has 3100:3000

    farmy "start", "notes"

    assert_exit 1
    assert_stderr "3100-3199"
    assert_stderr "notes"
    assert_stderr "shop"
    refute_container "notes"
  end

  test "a service whose host ports lie in two blocks is refused" do
    write_file "services/shop.yml", "repo: https://github.com/acme/shop.git\nimage: ruby:3.4\nports: [\"3100:3000\", \"5432:5432\"]\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "services/shop.yml"
    assert_stderr "5432"
    refute_container "shop"
  end

  test "a ports.yml in the folder is refused by name and ports: is pointed at" do
    write_file "ports.yml", "shop: 3100-3199\n"

    farmy "start", "shop"

    assert_exit 1
    assert_stderr "ports.yml"
    assert_stderr "ports:"
    refute_container "shop"
  end

  test "status shows every service's block, and - for a service without ports" do
    write_file "services/toolkit.yml", "repo: https://github.com/acme/toolkit.git\nimage: ruby:3.4\n"

    farmy "status"

    assert_success
    assert_stdout(/^shop\s.*3100-3199/)
    assert_stdout(/^notes\s.*3200-3299/)
    assert_stdout(/^toolkit\s+stopped\s+-\s/)
  end

  test "a published port listens on 127.0.0.1 when LAN_HOST is not set" do
    farmy "start", "shop" # ports: ["3100:3000"]; .env without LAN_HOST

    assert_listens_on "shop", 3100, "127.0.0.1"
  end

  test "with LAN_HOST the published ports listen on every interface" do
    settings lan_host: "workshop.local"

    farmy "start", "shop"

    assert_listens_on "shop", 3100, "0.0.0.0"
  end

  test "status says the ports are 127.0.0.1 only without LAN_HOST, and every interface with it" do
    farmy "status"
    assert_stdout(/^ports\s+127\.0\.0\.1 only/)
    assert_stdout "LAN_HOST"

    settings lan_host: "workshop.local"
    farmy "status"
    assert_stdout(/^ports\s+every interface \(LAN_HOST=workshop\.local\)/)
  end
end
