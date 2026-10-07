# Renders the cloud-init user_data for a house-ordered VM (#192).
#
# Procurement (#191) calls this with its planned operation's enrollment and
# the one-time token, then sends the result in its single create request. The
# token is the only secret in the document: no provider token, no resident
# key, no Rails secret. The runner source is embedded, so the document itself
# pins which runner the VM will run.
#
# The VM opens no inbound runner port. Host input is dropped except loopback,
# established traffic, ICMP and SSH; SSH is for Daniel's offline break-glass
# key only. Rails stays root-equivalent over the VM through the Hetzner
# project token (rebuild, rescue, user_data at create); this firewall limits
# the network, not Rails.
module RunnerUserData

  RUNNER_SOURCE_PATH = Rails.root.join("host-runner/souls_house_runner.py")
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
        tcp dport 22 accept
      }
    }
  NFT

  # Reloaded on every boot, before the network comes up. Debian's own
  # nftables.service is left disabled: its config flushes the whole ruleset.
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

  SYSTEMD_UNIT = <<~UNIT.freeze
    [Unit]
    Description=House host runner (enrollment and telemetry only)
    After=network-online.target docker.service
    Wants=network-online.target

    [Service]
    ExecStart=/usr/bin/python3 /opt/souls-house-runner/souls_house_runner.py
    Restart=on-failure
    RestartSec=30
    # A refused enrollment exits 2 or 3 and needs an operator, not a loop.
    RestartPreventExitStatus=2 3

    [Install]
    WantedBy=multi-user.target
  UNIT

  class TooLarge < StandardError; end

  module_function

  def render(enrollment:, token:, rails_url:, runtime_image: nil)
    raise ArgumentError, "rails_url must be https" unless URI.parse(rails_url).is_a?(URI::HTTPS)

    config = {
      "rails_url" => rails_url,
      "runner_id" => enrollment.public_id,
      "enrollment_token" => token,
      "runtime_image" => runtime_image
    }.compact

    document = {
      "package_update" => true,
      "packages" => %w[docker.io python3-cryptography nftables],
      "write_files" => [
        file("/etc/nftables.d/souls-house-input.nft", NFTABLES, "0644"),
        file("/etc/systemd/system/souls-house-firewall.service", FIREWALL_UNIT, "0644"),
        file("/etc/systemd/system/souls-house-runner.service", SYSTEMD_UNIT, "0644"),
        file("/opt/souls-house-runner/souls_house_runner.py", runner_source, "0755", encode: true),
        file("/etc/souls-house-runner/config.json", JSON.generate(config), "0600")
      ],
      "runcmd" => [
        %w[systemctl daemon-reload],
        %w[systemctl enable --now souls-house-firewall],
        %w[systemctl enable --now docker],
        %w[systemctl enable --now souls-house-runner]
      ]
    }

    rendered = "#cloud-config\n" + document.to_yaml.delete_prefix("---\n")
    raise TooLarge, "user_data is #{rendered.bytesize} bytes" if rendered.bytesize > HETZNER_USER_DATA_LIMIT

    rendered
  end

  def runner_source
    File.read(RUNNER_SOURCE_PATH)
  end

  def file(path, content, permissions, encode: false)
    entry = { "path" => path, "permissions" => permissions, "owner" => "root:root" }
    if encode
      entry.merge("encoding" => "b64", "content" => Base64.strict_encode64(content))
    else
      entry.merge("content" => content)
    end
  end

end
