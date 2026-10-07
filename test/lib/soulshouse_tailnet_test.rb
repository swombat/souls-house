require "test_helper"
require "open3"
require "tmpdir"

# Drives agent-runtime/soulshouse-tailnet against fake tailscale/tailscaled
# binaries. The fakes keep the node's BackendState and the connection-free
# "tailnet" in a JSON file and log every tailscale call.
class SoulshouseTailnetTest < ActiveSupport::TestCase

  SCRIPT = Rails.root.join("agent-runtime/soulshouse-tailnet")

  FAKE_TAILSCALED = <<~PYTHON
    #!/usr/bin/env python3
    import os, socket, sys, time, json
    args = dict(a.split("=", 1) for a in sys.argv[1:] if "=" in a)
    statedir, sock_path = args["--statedir"], args["--socket"]
    world = os.environ["FAKE_TS_WORLD"]
    config = json.load(open(world))
    if config.get("daemon_fails"):
        sys.exit(1)
    if config.get("ignore_term"):
        import signal
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    state_file = os.path.join(statedir, "tailscaled.state")
    if not os.path.exists(state_file):
        open(state_file, "w").write("{}")
    s = socket.socket(socket.AF_UNIX); s.bind(sock_path); s.listen(16)
    while True:
        conn, _ = s.accept()
        conn.close()
  PYTHON

  FAKE_TAILSCALE = <<~PYTHON
    #!/usr/bin/env python3
    import json, os, sys
    world_path = os.environ["FAKE_TS_WORLD"]
    world = json.load(open(world_path))
    sock = next(a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--socket="))
    args = [a for a in sys.argv[1:] if not a.startswith("--socket=")]
    import socket
    try:  # like the real CLI: no listening daemon, no answer
        probe = socket.socket(socket.AF_UNIX); probe.connect(sock); probe.close()
    except OSError:
        print("failed to connect to local tailscaled", file=sys.stderr); sys.exit(1)
    open(os.environ["FAKE_TS_LOG"], "a").write(" ".join(args) + "\\n")
    def save(): json.dump(world, open(world_path, "w"))
    cmd = args[0]
    if cmd == "status":
        report = {"BackendState": world["backend"], "Self": {"HostName": "soulshouse-test", "TailscaleIPs": ["100.64.0.9"]}}
        if world["backend"] == "NeedsLogin" and world.get("auth_url"):
            report["AuthURL"] = world["auth_url"]
        if world["backend"] == "Running":
            report["Peer"] = world.get("peers", {})
        print(json.dumps(report))
    elif cmd == "up":
        key = next((a.split("file:", 1)[1] for a in args if a.startswith("--auth-key=file:")), None)
        if world["backend"] == "NeedsLogin" and key is None:
            # Interactive: the daemon gets a login link and waits for a person.
            world["auth_url"] = "https://login.tailscale.com/a/fake%d" % (world.get("login_starts", 0) + 1)
            world["login_starts"] = world.get("login_starts", 0) + 1; save()
            print("\\nTo authenticate, visit:\\n\\n\\t" + world["auth_url"] + "\\n")
            print("timeout waiting for Tailscale service to enter a Running state", file=sys.stderr); sys.exit(1)
        if world["backend"] == "NeedsLogin":
            if key is None or open(key).read() != world["valid_key"]:
                print("backend error: invalid key: unable to validate API key", file=sys.stderr); sys.exit(1)
            world["joined_with"] = open(key).read()
        world["backend"] = "Running"; save()
    elif cmd == "logout":
        if world.get("logout_fails"):
            print("logout: control unreachable", file=sys.stderr); sys.exit(1)
        world["backend"] = "NeedsLogin"; world["logged_out"] = world.get("logged_out", 0) + 1; save()
    elif cmd == "down":
        world["backend"] = "Stopped"; save()
    elif cmd == "ping":
        sys.exit(0)
  PYTHON

  setup do
    @dir = Dir.mktmpdir("tailnet")
    @bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(@bin)
    { "tailscale" => FAKE_TAILSCALE, "tailscaled" => FAKE_TAILSCALED }.each do |name, body|
      File.write(File.join(@bin, name), body)
      File.chmod(0o755, File.join(@bin, name))
    end
    @world = File.join(@dir, "world.json")
    @log = File.join(@dir, "calls.log")
    @ssh_config = File.join(@dir, "ssh", "config")
    set_world("backend" => "NeedsLogin", "valid_key" => "tskey-auth-good")
  end

  teardown do
    pid_file = File.join(@dir, "state", "tailscaled.pid")
    Process.kill("TERM", File.read(pid_file).to_i) if File.exist?(pid_file)
  rescue Errno::ESRCH
  ensure
    FileUtils.remove_entry(@dir)
  end

  test "joins once with the key from a file, writes the SSH alias, and does not re-spend the key" do
    write_manifest(connection_id: "svc_1")

    out, err, status = tailnet("up")
    assert status.success?, err
    assert_includes out, "ssh dell  →  daniel@dell"
    assert_equal "tskey-auth-good", world["joined_with"]
    assert_no_match(/tskey-auth-good/, File.read(@log), "the key must not appear on a command line")
    assert_not File.exist?(File.join(@dir, "state", ".auth-key"))

    config = File.read(@ssh_config)
    assert_includes config, "Host dell"
    assert_includes config, "nc %h %p"
    assert_includes config, File.join(@dir, "ssh-keys", "id_ed25519")

    calls_before = File.readlines(@log).grep(/\Aup /).size
    _, err, status = tailnet("up")
    assert status.success?, err
    assert_equal calls_before, File.readlines(@log).grep(/\Aup /).size, "already running: no second up"
    assert_equal config, File.read(@ssh_config)
  end

  test "a rejected key explains that reusable keys expire" do
    write_manifest(connection_id: "svc_1", key: "tskey-auth-expired")

    _, err, status = tailnet("up")
    assert_not status.success?
    assert_match(/invalid key/, err)
    assert_match(/expire/, err)
  end

  test "boot without a grant logs the saved node out and removes it, but keeps the SSH key" do
    write_manifest(connection_id: "svc_1")
    assert tailnet("up").last.success?
    key = File.read(File.join(@dir, "ssh-keys", "id_ed25519.pub"))
    stop_fake_daemon # as after a container rebuild

    File.delete(manifest_path)
    out, err, status = tailnet("boot")
    assert status.success?, err
    assert_includes out, "left the tailnet"
    assert_equal 1, world["logged_out"]
    assert_not daemon_alive?, "the logout daemon is stopped afterwards"
    assert_not File.exist?(File.join(@dir, "state", "tailscaled.state"))
    assert_not_includes File.read(@ssh_config), "Host dell"
    assert_equal key, File.read(File.join(@dir, "ssh-keys", "id_ed25519.pub"))
  end

  test "an unconfirmed logout keeps the node state for the next boot and says so" do
    write_manifest(connection_id: "svc_1")
    assert tailnet("up").last.success?
    File.delete(manifest_path)
    set_world(world.merge("logout_fails" => true))

    _, err, status = tailnet("boot")
    assert_not status.success?
    assert_match(/could not confirm logout/, err)
    assert File.exist?(File.join(@dir, "state", "tailscaled.state"))
    assert_not_includes File.read(@ssh_config), "Host dell", "aliases go even when logout fails"
  end

  test "a daemon that ignores TERM is killed, confirmed gone, and only then is its state deleted" do
    write_manifest(connection_id: "svc_1")
    set_world(world.merge("ignore_term" => true))
    assert tailnet("up").last.success?
    File.delete(manifest_path)

    out, err, status = tailnet("boot")
    assert status.success?, err
    assert_includes out, "left the tailnet"
    assert_not daemon_alive?
    assert_not File.exist?(File.join(@dir, "state", "tailscaled.state"))
  end

  test "a daemon it cannot tie to a recorded PID is left alone and the state is kept" do
    write_manifest(connection_id: "svc_1")
    assert tailnet("up").last.success?
    File.delete(File.join(@dir, "state", "tailscaled.pid"))
    File.delete(manifest_path)

    _, err, status = tailnet("boot")
    assert_not status.success?
    assert_match(/could not be confirmed stopped/, err)
    assert daemon_alive?, "an unowned daemon is never signalled"
    assert File.exist?(File.join(@dir, "state", "tailscaled.state"))
    kill_fake_daemons
  end

  test "a recorded PID that now belongs to another process is not signalled" do
    write_manifest(connection_id: "svc_1")
    assert tailnet("up").last.success?
    bystander = Process.spawn("sleep", "30")
    File.write(File.join(@dir, "state", "tailscaled.pid"), "#{bystander}\n")
    File.delete(manifest_path)

    _, err, status = tailnet("boot")
    assert_not status.success?
    assert_match(/could not be confirmed stopped/, err)
    assert_nothing_raised { Process.kill(0, bystander) }
    assert File.exist?(File.join(@dir, "state", "tailscaled.state"))
  ensure
    Process.kill("KILL", bystander) rescue nil
    Process.wait(bystander) rescue nil
    kill_fake_daemons
  end

  test "a different integration's node is logged out before joining with the new key" do
    write_manifest(connection_id: "svc_1")
    assert tailnet("up").last.success?
    set_world(world.merge("valid_key" => "tskey-auth-second"))

    write_manifest(connection_id: "svc_2", key: "tskey-auth-second")
    _, err, status = tailnet("up")
    assert status.success?, err
    assert_equal 1, world["logged_out"]
    assert_equal "tskey-auth-second", world["joined_with"]
    assert_equal "svc_2", File.read(File.join(@dir, "state", "connection")).strip
  end

  test "refuses more than one granted Tailscale integration" do
    write_manifest(connection_id: "svc_1", extra: [ { "provider" => "tailscale", "connection_id" => "svc_2", "label" => "Other",
                                                       "credentials" => { "auth_key" => "tskey-auth-x" } } ])

    _, err, status = tailnet("up")
    assert_not status.success?
    assert_match(/2 Tailscale integrations/, err)
    assert_not File.exist?(File.join(@dir, "state", "tailscaled.state"))
  end

  test "refuses host entries that could inject into ssh_config" do
    write_manifest(connection_id: "svc_1", hosts: [ { "alias" => "dell", "machine" => "dell %h;evil" } ])

    _, err, status = tailnet("up")
    assert_not status.success?
    assert_match(/malformed host entry/, err)
    assert_not File.exist?(@ssh_config)
  end

  test "leaves the resident's own ssh_config entries in place and in force" do
    FileUtils.mkdir_p(File.dirname(@ssh_config))
    File.write(@ssh_config, "User everyone\nHost old\n  HostName example.com\n")
    write_manifest(connection_id: "svc_1")

    assert tailnet("up").last.success?
    config = File.read(@ssh_config)
    assert_includes config, "Host old"
    assert_operator config.index("Match all"), :<, config.index("User everyone")
  end

  test "every documented command resolves to a function" do
    out, err, status = Open3.capture3("python3", "-c", <<~PY, SCRIPT.to_s)
      import importlib.machinery, importlib.util, re, sys
      loader = importlib.machinery.SourceFileLoader("tailnet", sys.argv[1])
      spec = importlib.util.spec_from_loader("tailnet", loader)
      module = importlib.util.module_from_spec(spec)
      loader.exec_module(module)
      commands = re.findall(r"soulshouse-tailnet (\\w+)", module.__doc__)
      missing = [c for c in commands if not callable(getattr(module, c, None))]
      print(sorted(set(commands)), "missing:", missing)
      sys.exit(1 if missing else 0)
    PY
    assert status.success?, out + err
    assert_includes out, "'pubkey'"
    assert_includes out, "'status'"
  end

  test "pubkey prints one stable ed25519 public key, and needs a grant" do
    write_manifest(connection_id: "svc_1")
    first, err, status = tailnet("pubkey")
    assert status.success?, err
    assert_match(/\Assh-ed25519 \S+ soulshouse-test\n\z/, first)
    assert_equal first, tailnet("pubkey").first

    File.delete(manifest_path)
    _, err, status = tailnet("pubkey")
    assert_not status.success?
    assert_match(/no Tailscale integration/, err)
  end

  test "status reports the node and its machines, in text and JSON" do
    write_manifest(connection_id: "svc_1")
    assert tailnet("up").last.success?

    out, err, status = tailnet("status")
    assert status.success?, err
    assert_includes out, "state: Running"
    assert_includes out, "100.64.0.9"
    assert_includes out, "ssh dell  →  daniel@dell  (online)"

    out, err, status = tailnet("status", "--json")
    assert status.success?, err
    report = JSON.parse(out)
    assert report["granted"]
    assert_equal "Running", report["backend_state"]
    assert_equal [ { "alias" => "dell", "target" => "daniel@dell", "online" => true, "os" => nil } ], report["hosts"]
    assert_match(/\Assh-ed25519 /, report["pubkey"])
  end

  test "without an auth key, up starts a sign-in and reports the login link" do
    write_manifest(connection_id: "svc_1", key: nil, hosts: [])

    out, err, status = tailnet("up", "--json")
    assert status.success?, err
    report = JSON.parse(out)
    assert_equal "NeedsLogin", report["backend_state"]
    assert_equal "https://login.tailscale.com/a/fake1", report["auth_url"]
    assert_match(/\Assh-ed25519 /, report["pubkey"], "the key exists before sign-in, so it can be authorised meanwhile")
    assert_equal [], report["hosts"]

    out, err, status = tailnet("up")
    assert status.success?, err
    assert_includes out, "waiting for sign-in: https://login.tailscale.com/a/fake1"
    assert_equal 1, world["login_starts"], "a pending login is reused, not restarted"
    assert_equal 0, world.fetch("logged_out", 0), "a node waiting for sign-in is this integration's, not stale state"
  end

  test "once someone signs in, every machine on the tailnet becomes an ssh alias" do
    write_manifest(connection_id: "svc_1", key: nil, hosts: [])
    assert tailnet("up").last.success?
    set_world(world.merge("backend" => "Running", "peers" => {
      "k1" => { "DNSName" => "dell.tail1234.ts.net.", "HostName" => "dell", "TailscaleIPs" => [ "100.64.0.2", "fd7a::2" ], "Online" => true, "OS" => "linux" },
      "k2" => { "DNSName" => "danbook.tail1234.ts.net.", "HostName" => "Daniel's MacBook", "TailscaleIPs" => [ "100.64.0.3" ], "Online" => false, "OS" => "macOS" },
      "k3" => { "DNSName" => "evil%h;x.tail1234.ts.net.", "HostName" => "x", "TailscaleIPs" => [ "100.64.0.4" ], "Online" => true }
    }))

    out, err, status = tailnet("up", "--json")
    assert status.success?, err
    report = JSON.parse(out)
    assert_nil report["auth_url"]
    assert_equal %w[danbook dell], report["hosts"].map { |h| h["alias"] }
    assert_equal [ false, true ], report["hosts"].map { |h| h["online"] }

    config = File.read(@ssh_config)
    assert_includes config, "Host dell\n    HostName 100.64.0.2\n"
    assert_includes config, "Host danbook\n    HostName 100.64.0.3\n"
    assert_not_includes config, "evil"
    assert_equal 1, world["login_starts"]
  end

  test "status without a grant or a daemon says so and exits 3" do
    out, _, status = tailnet("status")
    assert_equal 3, status.exitstatus
    assert_includes out, "No Tailscale integration is granted"
  end

  private

  def tailnet(*args)
    Open3.capture3(
      {
        "PATH" => "#{@bin}:#{ENV.fetch('PATH')}",
        "HELIXKIT_SERVICES_FILE" => manifest_path,
        "SOULSHOUSE_TAILNET_STATE" => File.join(@dir, "state"),
        "SOULSHOUSE_TAILNET_SSH_DIR" => File.join(@dir, "ssh-keys"),
        "SOULSHOUSE_TAILNET_SSH_CONFIG" => @ssh_config,
        "SOULSHOUSE_TAILNET_DAEMON_WAIT" => "10",
        "AGENT_SLUG" => "test",
        "FAKE_TS_WORLD" => @world,
        "FAKE_TS_LOG" => @log
      },
      "python3", SCRIPT.to_s, *args
    )
  end

  def manifest_path
    File.join(@dir, "services.yml")
  end

  def write_manifest(connection_id:, key: "tskey-auth-good", hosts: [ { "alias" => "dell", "user" => "daniel", "machine" => "dell" } ], extra: [])
    File.write(manifest_path, {
      "version" => 1,
      "services" => [
        { "provider" => "tailscale", "connection_id" => connection_id, "label" => "Tailnet",
          "credentials" => key ? { "auth_key" => key } : {}, "metadata" => { "hosts" => hosts } }
      ] + extra
    }.to_yaml)
  end

  def world
    JSON.parse(File.read(@world))
  end

  def set_world(value)
    File.write(@world, JSON.generate(value))
  end

  def stop_fake_daemon
    pid = File.read(File.join(@dir, "state", "tailscaled.pid")).to_i
    Process.kill("TERM", pid)
    Process.wait(pid) rescue nil
    sleep 0.2
    FileUtils.rm_f(File.join(@dir, "state", "tailscaled.sock"))
    FileUtils.rm_f(File.join(@dir, "state", "tailscaled.pid"))
  end

  def kill_fake_daemons
    fake_daemon_pids.each { |pid| Process.kill("KILL", pid) rescue nil }
  end

  def fake_daemon_pids
    Dir.glob("/proc/[0-9]*/cmdline").filter_map do |path|
      path.split("/")[2].to_i if File.read(path).include?("--statedir=#{File.join(@dir, 'state')}")
    rescue Errno::ENOENT, Errno::ESRCH, Errno::EACCES
      nil
    end
  end

  def daemon_alive?
    # Any fake daemon still serving this test's state directory.
    Dir.glob("/proc/[0-9]*/cmdline").any? do |path|
      File.read(path).include?("--statedir=#{File.join(@dir, 'state')}")
    rescue Errno::ENOENT, Errno::ESRCH, Errno::EACCES
      false
    end
  end

end
