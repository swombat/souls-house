# Renders the setupScript for a house-created Boat sandbox (slice 2, ePokyY):
# the Boat twin of RunnerUserData's cloud-init.
#
# Boat has no cloud-init. Its one first-boot hook is a bash script it runs
# once, as the sandbox user with passwordless sudo, after the sandbox is
# ready, with a 64 KB limit; BoatProcurement reads the outcome back as
# setupStatus. The script installs the same pieces cloud-init does on
# Hetzner: the same runner config (the enrollment token is still the only
# secret), the same pinned-bundle fetch script and the same systemd units.
# systemd brings the runner back after every resume, including a cold one on
# a new machine, so nothing here needs to run twice.
#
# Two things differ, and both are deliberate:
# * the sandbox's id comes from Boat's reserved BOAT_ID variable and is
#   written where the runner reads it (Boat has no metadata service); a
#   missing or malformed BOAT_ID stops the script before anything is
#   installed, so the runner can never enroll under a guessed identity
# * no nftables input firewall of our own. The sandbox does have an IP;
#   what protects it is Boat's default ingress filtering (ports are closed
#   unless published), and Boat's own agent must keep reaching it. Even
#   with noEnv, the sandbox keeps a sandbox-scoped ASCII_TOKEN that can
#   publish its own ports, so a process inside the sandbox that can read
#   that token could open one. This is a property of Boat, not something
#   this script adds; the live bootstrap proof should record it.
#   Rails is root-equivalent over the sandbox through the API key, as it is
#   over a Hetzner VM through the project token.
module BoatSetupScript

  LIMIT = 64 * 1024
  SANDBOX_ID_PATH = "/etc/souls-house-runner/boat-sandbox-id".freeze
  PACKAGES = %w[python3-cryptography].freeze

  class TooLarge < StandardError; end

  module_function

  def render(enrollment:, token:, rails_url:, runtime_image: nil, commands_enabled: false)
    RunnerUserData.validate_origin!(rails_url)
    config = {
      "rails_url" => rails_url,
      "runner_id" => enrollment.public_id,
      "enrollment_token" => token,
      "birth_bundle_sha256" => RunnerBirthBundle.pin!(enrollment),
      "runtime_image" => runtime_image,
      # Only a literal true enables the command channel (#238).
      "commands_enabled" => (true if commands_enabled == true)
    }.compact

    files = [
      [ "/etc/souls-house-runner/config.json", JSON.generate(config), "0600" ],
      [ "/etc/systemd/system/souls-house-runner.service", RunnerUserData::SYSTEMD_UNIT, "0644" ],
      [ "/etc/systemd/system/souls-house-runner-fetch.service", RunnerUserData::FETCH_UNIT, "0644" ],
      [ RunnerUserData::FETCH_SCRIPT, RunnerUserData.compact_source(File.read(RunnerUserData::FETCH_SOURCE_PATH)), "0700" ]
    ]

    script = <<~BASH
      #!/bin/bash
      # souls.house runner bootstrap for a Boat sandbox. Prints no secrets.
      set -euo pipefail
      umask 077
      if [[ ! "${BOAT_ID:-}" =~ ^bx_[23456789abcdefghjkmnpqrstuvwxyz]{8}$ ]]; then
        echo "souls-house: BOAT_ID is missing or malformed; refusing to install the runner" >&2
        exit 3
      fi
      put() {
        sudo install -D -o root -g root -m "$2" /dev/null "$1"
        base64 -d | sudo tee "$1" >/dev/null
      }
      sudo DEBIAN_FRONTEND=noninteractive apt-get update -q
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq #{PACKAGES.join(' ')}
      printf '%s\\n' "$BOAT_ID" | base64 | put #{SANDBOX_ID_PATH} 0644
      #{files.map { |path, content, mode| "put #{path} #{mode} <<'B64'\n#{Base64.encode64(content)}B64" }.join("\n")}
      sudo install -d -o root -g root -m 0700 /var/lib/souls-house-runner
      sudo systemctl daemon-reload
      sudo systemctl enable --now docker
      # Enabled for later boots and resumes; its condition skips it until installed.
      sudo systemctl enable souls-house-runner
      # --no-block: the fetch may retry for minutes; the script must not wait.
      sudo systemctl enable --now --no-block souls-house-runner-fetch
      echo "souls-house: runner bootstrap installed"
    BASH

    raise TooLarge, "setupScript is #{script.bytesize} bytes" if script.bytesize > LIMIT

    script
  end

end
