require "test_helper"
require "open3"
require "tmpdir"

# Drives agent-runtime/soulshouse-ghost against a fake Ghost Admin API that
# checks every token the way Ghost does and logs each request.
class SoulshouseGhostTest < ActiveSupport::TestCase

  SCRIPT = Rails.root.join("agent-runtime/soulshouse-ghost")
  KEY_ID = "6489f0c2a1b2c3d4e5f60718".freeze
  SECRET = ("cd" * 32).freeze
  KEY = "#{KEY_ID}:#{SECRET}".freeze

  FAKE_GHOST = <<~PYTHON
    import base64, hashlib, hmac, json, sys, time
    from http.server import BaseHTTPRequestHandler, HTTPServer
    KID, SECRET, LOG = sys.argv[1], bytes.fromhex(sys.argv[2]), sys.argv[3]
    posts = {"p1": {"id": "p1", "title": "Old", "status": "draft", "url": "https://blog.example.com/p/p1/",
                    "updated_at": "2026-10-22T10:00:00.000Z"},
             # Scheduled in Ghost Admin to publish *and send*: Ghost emails it on publication.
             "p3": {"id": "p3", "title": "Letter", "status": "scheduled", "url": "https://blog.example.com/p/p3/",
                    "updated_at": "2026-10-22T10:00:00.000Z", "newsletter_id": "n1",
                    "newsletter": {"id": "n1", "name": "Weekly letter"}, "email": None},
             # Sent once and failed: Ghost retries a failed email on publication.
             "p4": {"id": "p4", "title": "Retry", "status": "draft", "url": "https://blog.example.com/p/p4/",
                    "updated_at": "2026-10-22T10:00:00.000Z", "newsletter_id": "n1",
                    "newsletter": {"id": "n1", "name": "Weekly letter"}, "email": {"id": "e1", "status": "failed"}}}

    def shown(post, path):
        # Like Ghost: relations appear only when asked for with include=.
        post = dict(post)
        for relation in ("newsletter", "email"):
            if relation not in path.split("include=")[-1] or "include=" not in path:
                post.pop(relation, None)
            else:
                post.setdefault(relation, None)
        return post
    def unb64(s): return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def answer(self, code, body):
            raw = json.dumps(body).encode()
            self.send_response(code); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)
        def handle_any(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            entry = {"method": self.command, "path": self.path, "auth": self.headers.get("Authorization"),
                     "version": self.headers.get("Accept-Version"), "type": self.headers.get("Content-Type"),
                     "body": body.decode("utf-8", "replace")}
            open(LOG, "a").write(json.dumps(entry) + "\\n")
            scheme, _, token = (self.headers.get("Authorization") or "").partition(" ")
            try:
                h, p, s = token.split(".")
                header, claims = json.loads(unb64(h)), json.loads(unb64(p))
                good = hmac.compare_digest(unb64(s), hmac.new(SECRET, f"{h}.{p}".encode(), hashlib.sha256).digest())
                ok = scheme == "Ghost" and good and header["kid"] == KID and claims["aud"] == "/admin/" \\
                    and claims["exp"] - claims["iat"] <= 300 and claims["exp"] > time.time()
            except Exception:
                ok = False
            if not ok:
                return self.answer(401, {"errors": [{"message": "Invalid token"}]})
            path = self.path.split("?")[0]
            if path == "/ghost/api/admin/posts/moved/":
                self.send_response(302); self.send_header("Location", "http://127.0.0.1:%d/elsewhere/" % self.server.server_port)
                self.send_header("Content-Length", "0"); self.end_headers(); return
            if path == "/ghost/api/admin/site/":
                return self.answer(200, {"site": {"title": "Lume writes", "url": "https://blog.example.com/", "version": "5.101"}})
            if path == "/ghost/api/admin/posts/" and self.command == "GET":
                return self.answer(200, {"posts": list(posts.values())})
            if path == "/ghost/api/admin/posts/" and self.command == "POST":
                post = json.loads(body)["posts"][0]
                post.update(id="p2", url="https://blog.example.com/p/p2/", updated_at="2026-10-22T11:00:00.000Z")
                posts["p2"] = post
                return self.answer(201, {"posts": [post]})
            if path.startswith("/ghost/api/admin/posts/"):
                pid = path.split("/")[-2]
                if pid not in posts:
                    return self.answer(404, {"errors": [{"message": "Post not found."}]})
                if self.command == "GET":
                    if pid == "p1" and "include=" in self.path and posts[pid].get("title") == "race" and not posts[pid].get("newsletter"):
                        # Someone sets a newsletter right after the safety check.
                        answer = shown(posts[pid], self.path)
                        posts[pid].update(newsletter_id="n1", newsletter={"id": "n1", "name": "Weekly letter"},
                                          updated_at="2026-10-22T10:30:00.000Z")
                        return self.answer(200, {"posts": [answer]})
                    return self.answer(200, {"posts": [shown(posts[pid], self.path)]})
                change = json.loads(body)["posts"][0]
                if change.get("updated_at") != posts[pid]["updated_at"]:
                    return self.answer(409, {"errors": [{"message": "Saving failed! Someone else is editing this post."}]})
                posts[pid].update(change, updated_at="2026-10-22T12:00:00.000Z")
                return self.answer(200, {"posts": [posts[pid]]})
            if path == "/ghost/api/admin/images/upload/":
                return self.answer(201, {"images": [{"url": "https://blog.example.com/content/images/cat.png"}]})
            self.answer(404, {"errors": [{"message": "Resource not found"}]})
        do_GET = do_POST = do_PUT = handle_any
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
  PYTHON

  # Stands in for python3-markdown, so both body paths are tested whether or
  # not the real library is installed where the suite runs.
  FAKE_MARKDOWN = <<~PYTHON
    def markdown(text, **options):
        return "<h1>" + text.splitlines()[0].lstrip("# ") + "</h1>"
  PYTHON

  setup do
    @dir = Dir.mktmpdir("soulshouse-ghost")
    @log = File.join(@dir, "requests.log")
    File.write(File.join(@dir, "fake_ghost.py"), FAKE_GHOST)
    @server_in, @server_out, @server = Open3.popen2("python3", File.join(@dir, "fake_ghost.py"), KEY_ID, SECRET, @log)
    @port = @server_out.gets.to_i
    write_manifest([ connection("svc_blog") ])
    Dir.mkdir(File.join(@dir, "md"))
    File.write(File.join(@dir, "md", "markdown.py"), FAKE_MARKDOWN)
    File.write(File.join(@dir, "article.md"), "# Hello house\n\nFirst paragraph.\n")
  end

  teardown do
    Process.kill("TERM", @server.pid) rescue nil
    @server.join
    FileUtils.remove_entry(@dir)
  end

  def connection(id, api_base: "http://127.0.0.1:#{@port}/ghost/api/admin")
    { "connection_id" => id, "provider" => "ghost", "credentials" => { "admin_api_key" => KEY },
      "metadata" => { "api_base" => api_base, "site_url" => "https://blog.example.com" } }
  end

  def write_manifest(services)
    File.write(File.join(@dir, "services.yml"), { "services" => services }.to_yaml)
  end

  def ghost(*args, markdown: true)
    env = { "SOULSHOUSE_SERVICES_FILE" => File.join(@dir, "services.yml"), "PYTHONPATH" => markdown ? File.join(@dir, "md") : "" }
    Open3.capture3(env, "python3", SCRIPT.to_s, *args, chdir: @dir)
  end

  def requests = File.exist?(@log) ? File.readlines(@log).map { |line| JSON.parse(line) } : []

  test "a draft from Markdown goes to Ghost as HTML, signed, and stays a draft" do
    out, err, status = ghost("draft", "--title", "Hello", "--file", "article.md", "--tags", "essays, house")

    assert status.success?, err
    assert_match "Draft saved.", out
    assert_match "soulshouse-ghost publish p2", out
    request = requests.last
    assert_equal [ "POST", "/ghost/api/admin/posts/?source=html" ], [ request["method"], request["path"] ]
    assert_equal "v5.0", request["version"]
    post = JSON.parse(request["body"])["posts"].first
    assert_equal "draft", post["status"]
    assert_equal "<h1>Hello house</h1>", post["html"]
    assert_equal [ { "name" => "essays" }, { "name" => "house" } ], post["tags"]
  end

  test "without a Markdown library the body is one Markdown card" do
    _out, err, status = ghost("draft", "--title", "Hello", "--file", "article.md", markdown: false)

    skip "python3-markdown is installed here" if requests.last["path"].include?("source=html")
    assert status.success?, err
    assert_equal "/ghost/api/admin/posts/", requests.last["path"]
    lexical = JSON.parse(JSON.parse(requests.last["body"])["posts"].first["lexical"])
    assert_equal [ { "type" => "markdown", "version" => 1, "markdown" => "# Hello house\n\nFirst paragraph.\n" } ], lexical.dig("root", "children")
  end

  test "publishing sends the current updated_at and never asks Ghost to email members" do
    out, err, status = ghost("publish", "p1")

    assert status.success?, err
    assert_match "Published (public now; not emailed)", out
    check, put = requests.last(2)
    assert_equal "/ghost/api/admin/posts/p1/?include=newsletter,email", check["path"]
    assert_equal "PUT", put["method"]
    assert_equal "/ghost/api/admin/posts/p1/", put["path"]
    assert_no_match(/newsletter|email_segment/, put["path"] + put["body"])
    assert_equal({ "status" => "published", "updated_at" => "2026-10-22T10:00:00.000Z" }, JSON.parse(put["body"])["posts"].first)
  end

  test "refuses to publish a post Ghost would email on publication" do
    _out, err, status = ghost("publish", "p3")

    assert_not status.success?
    assert_match "set to be sent to Weekly letter", err
    assert_equal [ "GET" ], requests.map { |request| request["method"] }.uniq
  end

  test "refuses a newsletter post even when its email exists (a failed one is retried)" do
    _out, err, status = ghost("publish", "p4")

    assert_not status.success?
    assert_match "set to be sent to Weekly letter", err
    assert_equal [ "GET" ], requests.map { |request| request["method"] }.uniq
  end

  test "publishes with the checked snapshot, so a newsletter set after the check stops it" do
    _out, err, status = ghost("update", "p1", "--title", "race")
    assert status.success?, err

    _out, err, status = ghost("publish", "p1")

    assert_not status.success?
    assert_match "HTTP 409", err
    put = requests.last
    assert_equal "PUT", put["method"]
    assert_equal "2026-10-22T12:00:00.000Z", JSON.parse(put["body"])["posts"].first["updated_at"]
  end

  test "never follows a redirect with the signed token" do
    _out, err, status = ghost("publish", "moved")

    assert_not status.success?
    assert_match "redirect (302)", err
    assert_empty requests.select { |request| request["path"].start_with?("/elsewhere") }
    assert_equal 1, requests.size
  end

  test "update keeps the post's status and refuses an empty change" do
    _out, err, status = ghost("update", "p1", "--title", "New title")
    assert status.success?, err
    assert_equal({ "title" => "New title", "updated_at" => "2026-10-22T10:00:00.000Z" }, JSON.parse(requests.last["body"])["posts"].first)

    _out, err, status = ghost("update", "p1")
    assert_not status.success?
    assert_match "Nothing to change", err
  end

  test "Ghost's own error reaches the resident" do
    _out, err, status = ghost("publish", "nope")

    assert_not status.success?
    assert_match "Ghost answered HTTP 404: Post not found.", err
  end

  test "lists posts, uploads an image, and takes --json after the command" do
    out, err, status = ghost("posts", "--json")
    assert status.success?, err
    assert_equal "p1", JSON.parse(out)["posts"].first["id"]

    File.binwrite(File.join(@dir, "cat.png"), "\x89PNG fake")
    out, err, status = ghost("image", "cat.png")
    assert status.success?, err
    assert_equal "https://blog.example.com/content/images/cat.png", out.strip
    assert_match "multipart/form-data", requests.last["type"]
  end

  test "with several sites it asks which, and the key never appears in a URL or the output" do
    write_manifest([ connection("svc_blog"), connection("svc_other") ])
    _out, err, status = ghost("posts")
    assert_not status.success?
    assert_match "Several Ghost sites are connected (svc_blog", err

    out, err, status = ghost("--connection", "svc_other", "site")
    assert status.success?, err
    assert_match "Lume writes", out
    assert_match "connection svc_other", out
    requests.each { |request| assert_not_includes request["path"], SECRET }
    assert_not_includes out + err, SECRET
  end

end
