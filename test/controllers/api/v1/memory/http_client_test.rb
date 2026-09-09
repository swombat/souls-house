require "test_helper"
require "socket"
require "tmpdir"

class Api::V1::Memory::HttpClientTest < ActionDispatch::IntegrationTest

  test "Python HTTP client forms recalls opens and commits against Rails routes" do
    resident = agents(:research_assistant)
    resident.update_columns(runtime: "external")
    key = ApiKey.generate_for(users(:user_1), name: "Synthetic HTTP smoke", agent: resident)
    server = TCPServer.new("127.0.0.1", 0)
    Dir.mktmpdir("mnemodyne-http-", Rails.root.join("tmp")) do |root|
      File.write(File.join(root, "journal.md"), "Synthetic source body")
      env = { "SOULSHOUSE_APP_URL" => "http://127.0.0.1:#{server.addr[1]}", "SOULSHOUSE_BEARER_TOKEN" => key.raw_token,
        "AGENT_IDENTITY_PATH" => root, "MNEMODYNE_RECALL_CACHE" => File.join(root, "receipts"),
        "PYTHONPATH" => Rails.root.join("agent-runtime").to_s }
      script = <<~PY
        import memory_client as m
        import io, json, contextlib, sys
        from pathlib import Path
        c = m.Client()
        assert c.request("POST", "vault")["enabled"]
        # Execute the documented JSON through the real CLI and real HTTP, not a
        # separate hand-maintained request fixture that could hide schema drift.
        reference = Path(m.__file__).with_name("docs").joinpath("memory-quick-reference.md").read_text()
        payload = json.loads(next(line for line in reference.splitlines() if line.startswith('{"memory":')))
        payload["memory"]["source_uris"] = ["identity://journal.md"]
        sys.argv = ["house-memory", "--key", "http-formation", "form"]
        sys.stdin = io.StringIO(json.dumps(payload))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            assert m.main() == 0
        receipt = json.loads(out.getvalue())
        n = receipt["node"]
        assert len(receipt["connections"]) == 2
        r = c.recall(seeds=[n["id"]])
        assert n["id"] in [item["id"] for item in r["results"]]
        assert c.open_source(r["recall_id"], n["id"]) == "Synthetic source body"
        c.use(r["recall_id"], n["id"])
        print("HTTP smoke passed")
      PY
      Open3.popen3(env, "python3", "-c", script) do |input, output, error, process|
        input.close
        # The socket is real; dispatch remains in the fixture-owning test thread.
        # This tests client wire format and the full Rails authorization/routes
        # without a second DB owner or an unguarded test server.
        5.times do
          assert IO.select([ server ], nil, nil, 10), "Synthetic client did not connect"
          socket = server.accept
          method, path = socket.gets.split.first(2)
          headers = {}
          while (line = socket.gets) && line != "\r\n"
            name, value = line.split(":", 2)
            headers[name] = value.strip
          end
          raw = socket.read(headers.fetch("Content-Length", "0").to_i)
          public_send(method.downcase, path, params: raw.empty? ? nil : JSON.parse(raw),
            headers: headers.slice("Authorization", "Idempotency-Key"), as: :json)
          body = response.body
          socket.write("HTTP/1.1 #{response.status} Result\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
          socket.close
          assert_response :success
        end
        assert process.value.success?, error.read
        assert_equal "HTTP smoke passed", output.read.strip
      end
    end
    assert_equal 1, resident.reload.memory_vault.uses.count
  ensure
    server&.close
  end

end
