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
    if json.load(open(world)).get("daemon_fails"):
        sys.exit(1)
    state_file = os.path.join(statedir, "tailscaled.state")
    if not os.path.exists(state_file):
        open(state_file, "w").write("{}")
    s = socket.socket(socket.AF_UNIX); s.bind(sock_path); s.listen(1)
    while True:
        time.sleep(1)
  PYTHON

  FAKE_TAILSCALE = <<~PYTHON
    #!/usr/bin/env python3
    import json, os, sys
    world_path = os.environ["FAKE_TS_WORLD"]
    world = json.load(open(world_path))
    args = [a for a in sys.argv[1:] if not a.startswith("--socket=")]
    open(os.environ["FAKE_TS_LOG"], "a").write(" ".join(args) + "\\n")
    def save(): json.dump(world, open(world_path, "w"))
    cmd = args[0]
    if cmd == "status":
        print(json.dumps({"BackendState": world["backend"], "Self": {"HostName": "soulshouse-test", "TailscaleIPs": ["100.64.0.9"]}}))
    elif cmd == "up":
        key = next((a.split("file:", 1)[1] for a in args if a.startswith("--auth-key=file:")), None)
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
          "credentials" => { "auth_key" => key }, "metadata" => { "hosts" => hosts } }
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

  def daemon_alive?
    # Any fake daemon still serving this test's state directory.
    Dir.glob("/proc/[0-9]*/cmdline").any? do |path|
      File.read(path).include?("--statedir=#{File.join(@dir, 'state')}")
    rescue Errno::ENOENT, Errno::ESRCH, Errno::EACCES
      false
    end
  end

end
