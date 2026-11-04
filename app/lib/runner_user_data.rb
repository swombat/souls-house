# Renders the cloud-init user_data for a house-ordered VM (#192).
#
# Procurement (#191) calls this with its planned operation's enrollment and
# the one-time token, then sends the result in its single create request. The
# token is the only secret in the document: no provider token, no resident
# key, no Rails secret. The runner is not embedded (#779): the document pins
# its digest, and a small fetch script installs exactly those bytes from the
# house (RunnerBirthBundle) before the runner first starts.
#
# The VM opens no inbound runner port. Host input is dropped except loopback,
# established traffic, ICMP and SSH; SSH is for Daniel's offline break-glass
# key only. Rails stays root-equivalent over the VM through the Hetzner
# project token (rebuild, rescue, user_data at create); this firewall limits
# the network, not Rails.
require "rubygems/package"
require "open3"

module RunnerUserData

  RUNNER_SOURCE_PATH = Rails.root.join("host-runner/souls_house_runner.py")
  CARRY_SHAPE_PATH = Rails.root.join("host-runner/carry_shape.sh")
  FETCH_SOURCE_PATH = Rails.root.join("host-runner/birth_fetch.py")
  FETCH_SCRIPT = "/usr/local/lib/souls-house-runner/birth_fetch.py".freeze
  # Must stay under Agents::VmBirthPolicy::BIRTH_DEADLINE: the house fails a
  # placement that never enrolls; the script only stops retrying.
  FETCH_GIVE_UP_AFTER = 40.minutes
  HETZNER_USER_DATA_LIMIT = 32 * 1024

  # Declare, delete, define: loading this file twice leaves one copy.
  NFTABLES = <<~NFT.freeze
    #!/usr/sbin/nft -f
    table inet souls_house_input
    delete table inet souls_house_input
    table inet souls_house_input {
      chain input {
        type filter hook input priority filter; policy drop;
        iif "lo" accept
        ct state established,related accept
        ct state invalid drop
        meta l4proto { icmp, ipv6-icmp } accept
        # DHCP replies (v4 and v6) can arrive as broadcasts conntrack
        # does not match; without these the VM can lose its address on reboot.
        udp sport 67 udp dport 68 accept
        udp sport 547 udp dport 546 accept
        tcp dport 22 accept
      }
    }
  NFT

  # Reloaded on every boot, before the network comes up. Debian's own
  # nftables.service is masked in runcmd: its config flushes the whole ruleset.
  FIREWALL_UNIT = <<~UNIT.freeze
    [Unit]
    Description=House host input firewall
    DefaultDependencies=no
    Before=network-pre.target
    Wants=network-pre.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/usr/sbin/nft -f /etc/nftables.d/souls-house-input.nft

    [Install]
    WantedBy=multi-user.target
  UNIT

  # Retries every 30 s until the pinned runner is installed; the script exits
  # 3 once FETCH_GIVE_UP_AFTER has passed since its first attempt, across
  # reboots. On success it starts the runner itself.
  FETCH_UNIT = <<~UNIT.freeze
    [Unit]
    Description=House host runner fetch (the bundle this VM's user_data pins)
    After=network-online.target
    Wants=network-online.target
    StartLimitIntervalSec=0

    [Service]
    Type=oneshot
    ExecStart=/usr/bin/python3 #{FETCH_SCRIPT}
    TimeoutStartSec=300
    Restart=on-failure
    RestartSec=30
    RestartPreventExitStatus=3

    [Install]
    WantedBy=multi-user.target
  UNIT

  SYSTEMD_UNIT = <<~UNIT.freeze
    [Unit]
    Description=House host runner (enrollment, telemetry and, when enabled, resident commands)
    After=network-online.target docker.service
    Wants=network-online.target
    # Skipped, not failed, until the fetch has installed a verified runner.
    ConditionPathExists=/opt/souls-house-runner/current/bundle.sha256

    [Service]
    ExecStart=/usr/bin/python3 /opt/souls-house-runner/souls_house_runner.py
    Restart=on-failure
    RestartSec=30
    # A refused enrollment or a bad origin exits 2, 3 or 4 and needs an
    # operator, not a loop.
    RestartPreventExitStatus=2 3 4

    [Install]
    WantedBy=multi-user.target
  UNIT

  class TooLarge < StandardError; end
  class PackagingFailed < StandardError; end

  module_function

  def render(enrollment:, token:, rails_url:, runtime_image: nil, commands_enabled: false)
    validate_origin!(rails_url)
    birth_bundle_sha256 = RunnerBirthBundle.pin!(enrollment)

    config = {
      "rails_url" => rails_url,
      "runner_id" => enrollment.public_id,
      "enrollment_token" => token,
      "birth_bundle_sha256" => birth_bundle_sha256,
      "runtime_image" => runtime_image,
      # Only a literal true enables the command channel (#238).
      "commands_enabled" => (true if commands_enabled == true)
    }.compact

    document = {
      "package_update" => true,
      # A new VM starts on the current kernel (KernelReboot): upgrade at
      # birth and, when that leaves /var/run/reboot-required, reboot once
      # before runcmd. cloud-init runs runcmd on the next boot, so the runner
      # first starts, and the resident first wakes, on the new kernel.
      "package_upgrade" => true,
      "package_reboot_if_required" => true,
      "packages" => %w[docker.io docker-cli python3-cryptography nftables],
      "write_files" => [
        file("/etc/nftables.d/souls-house-input.nft", NFTABLES, "0644"),
        file("/etc/systemd/system/souls-house-firewall.service", FIREWALL_UNIT, "0644"),
        file("/etc/systemd/system/souls-house-runner.service", SYSTEMD_UNIT, "0644"),
        file("/etc/systemd/system/souls-house-runner-fetch.service", FETCH_UNIT, "0644"),
        file(FETCH_SCRIPT, compact_source(File.read(FETCH_SOURCE_PATH)), "0700", encode: :gzip),
        file("/etc/souls-house-runner/config.json", JSON.generate(config), "0600")
      ],
      "runcmd" => [
        # Debian's own nftables.service flushes the whole ruleset when it
        # starts or stops. Masked first, so nothing can enable it later and
        # wipe the house rules.
        %w[systemctl mask nftables.service],
        %w[systemctl daemon-reload],
        %w[systemctl enable --now souls-house-firewall],
        %w[systemctl enable --now docker],
        # Enabled for later boots; its condition skips it until installed.
        %w[systemctl enable souls-house-runner],
        # --no-block: the fetch may retry for minutes; runcmd must not wait.
        %w[systemctl enable --now --no-block souls-house-runner-fetch]
      ]
    }

    rendered = "#cloud-config\n" + document.to_yaml.delete_prefix("---\n")
    raise TooLarge, "user_data is #{rendered.bytesize} bytes" if rendered.bytesize > HETZNER_USER_DATA_LIMIT

    rendered
  end

  # The runner posts its token to this origin, so it must be exactly an HTTPS
  # origin: no credentials, path, query or fragment.
  def validate_origin!(rails_url)
    uri = URI.parse(rails_url)
    valid = uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? &&
      [ "", "/" ].include?(uri.path) && uri.query.nil? && uri.fragment.nil?
    raise ArgumentError, "rails_url must be a bare https origin" unless valid
  rescue URI::InvalidURIError
    raise ArgumentError, "rails_url must be a bare https origin"
  end

  def runner_source
    File.read(RUNNER_SOURCE_PATH)
  end

  # Two packages from one tree (#426 3C). `birth` (the runner and the backup
  # proxy) is what a new VM fetches at birth (#779), and what every runner, old or new, can
  # unpack. `full` adds the carry modules a migration's restore needs; only a
  # runner already on a birth package of this release accepts it.
  BIRTH_FILES = %w[souls_house_runner.py backup_proxy.py].freeze
  CARRY_FILES = %w[carry_restore.py carry_shape.sh].freeze

  def source_bundle(full: false)
    io = StringIO.new("".b)
    members = { "souls_house_runner.py" => [ compact_source(runner_source), 0755 ],
      "backup_proxy.py" => [ compact_source(File.read(Rails.root.join("host-runner/backup_proxy.py"))), 0644 ] }
    if full
      members["carry_restore.py"] = [ compact_source(File.read(Rails.root.join("host-runner/carry_restore.py"))), 0644 ]
      members["carry_shape.sh"] = [ File.read(CARRY_SHAPE_PATH), 0644 ]
    end
    members.each do |name, (source, mode)|
      # Explicit mtime: TarWriter otherwise embeds the process's epoch.
      io.write(Gem::Package::TarHeader.new(name:, prefix: "", mode:, size: source.bytesize, mtime: 1).to_s)
      io.write(source)
      io.write("\0" * ((512 - source.bytesize % 512) % 512))
    end
    io.write("\0" * 1024)
    io.string
  end

  # Comments, formatting and docstrings go; executable behaviour stays: the
  # compacted module must parse to exactly the original's AST with its
  # docstrings removed, and a module that reads __doc__ is refused, since
  # there removing them would change behaviour. Docstrings came out in #593,
  # when the runner reached Hetzner's user_data margin.
  DOCSTRING_STRIP = <<~PYTHON.freeze
    def strip_docstrings(tree):
        for node in ast.walk(tree):
            if isinstance(node, (ast.Name, ast.Attribute)) and "__doc__" in (getattr(node, "id", None), getattr(node, "attr", None)):
                raise ValueError("runner reads __doc__")
        for node in ast.walk(tree):
            if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
                body = node.body
                if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) and isinstance(body[0].value.value, str):
                    node.body = body[1:] or [ast.Pass()]
        return tree
  PYTHON

  def compact_source(source)
    script = <<~PYTHON
      import ast, sys
      #{DOCSTRING_STRIP.gsub("\n", "\n      ").rstrip}
      original = strip_docstrings(ast.parse(sys.stdin.read()))
      compact = ast.unparse(original) + "\\n"
      if ast.dump(original, include_attributes=False) != ast.dump(ast.parse(compact), include_attributes=False):
          raise ValueError("runner AST changed")
      sys.stdout.write(compact)
    PYTHON
    output, _error, status = Open3.capture3("timeout", "10", "python3", "-c", script, stdin_data: source)
    raise PackagingFailed, "Cannot compact runner source safely" unless status.success?

    output
  end

  def compressed_source_bundle(full: false)
    output, _error, status = Open3.capture3("timeout", "10", "xz", "-6", "--stdout",
      stdin_data: source_bundle(full:), binmode: true)
    raise PackagingFailed, "Cannot package runner source with xz" unless status.success?

    output
  end

  # A fixed gzip mtime keeps the document identical for identical source.
  def file(path, content, permissions, encode: false)
    entry = { "path" => path, "permissions" => permissions, "owner" => "root:root" }
    case encode
    when :gzip
      entry.merge("encoding" => "gz+b64", "content" => Base64.strict_encode64(gzip(content)))
    when true
      entry.merge("encoding" => "b64", "content" => Base64.strict_encode64(content))
    else
      entry.merge("content" => content)
    end
  end

  def gzip(content)
    io = StringIO.new("".b)
    writer = Zlib::GzipWriter.new(io, Zlib::BEST_COMPRESSION)
    writer.mtime = 1
    writer.write(content)
    writer.close
    io.string
  end

end
