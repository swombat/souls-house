require "test_helper"

# Phase 1 of the forkable-house plan (docs/2026-09-07-forkable-house-plan-from-lume.md):
# "one file separates a house from the code" — config/house.env(.example).
# Nothing else in the repository may name a specific installation. This test
# is the tripwire that keeps that true as the codebase grows.
class IdentityLeakTest < ActiveSupport::TestCase

  SCAN_ROOTS = %w[app config lib scripts].freeze

  # Daniel's SSH username, the current server's IP, its SSH alias, and its
  # non-standard SSH port. None of these may appear outside house.env.
  FORBIDDEN_STRINGS = %w[dtenner 95.217.118.47 ssh://misc 12222].freeze

  EXCLUDED_FILES = %w[
    config/deploy.yml
    config/house.env
    config/house.env.example
    config/database.yml
    config/local_instance.rb
  ].freeze
  EXCLUDED_DIR_PREFIXES = %w[config/credentials/].freeze

  # Deliberate exceptions to FORBIDDEN_STRINGS: these name a *specific past
  # artifact*, kept for backward-compat recognition, not the current
  # install's identity. Same spirit as the plan's "deliberately untouched"
  # list (DB names, the network alias, the transition alias).
  FORBIDDEN_STRING_ALLOWLIST = {
    "app/jobs/hosted_agent_runtime_reconcile_job.rb" =>
      "dtenner/helix-kit-agent-runtime is a legacy Docker Hub repo name kept " \
      "for backward-compat image reconciliation, not this install's identity"
  }.freeze

  # Files where "souls.house" legitimately remains: either the default
  # argument of an ENV.fetch/ENV[] fallback (Phase 1's point is exactly that
  # a fork setting no SOULSHOUSE_* vars gets today's upstream behaviour), or
  # plain user-facing prose — the product introducing itself by name. Add an
  # entry here only after checking it's one of those two things, not a
  # config value that should read from house.env instead.
  SOULS_HOUSE_ALLOWLIST = {
    # --- ENV.fetch/ENV[] fallback defaults ---
    "config/environments/production.rb" => "SOULSHOUSE_DOMAIN / smtp from-address fallback defaults",
    "app/mailers/application_mailer.rb" => "SOULSHOUSE_MAIL_FROM fallback default",
    "app/models/setting.rb" => "SOULSHOUSE_SITE_NAME fallback default",

    # --- user-facing copy: the product introducing itself by name ---
    "app/models/agent.rb" => "validation error text shown to residents",
    "app/lib/agent_repo_creator.rb" => "GitHub deploy key title / User-Agent header",
    "app/lib/notices/renderer.rb" => "standing notice copy",
    "app/lib/external_agent_telegram_request.rb" => "Telegram notification copy",
    "app/jobs/safeguard_owner_notice_job.rb" => "Telegram notice copy",
    "app/jobs/prepare_telegram_media_job.rb" => "Telegram error copy",
    "app/jobs/process_telegram_update_job.rb" => "Telegram notice/error copy",
    "app/jobs/safeguard_cold_offer_job.rb" => "safeguard reclaim copy",
    "app/jobs/model_change_orientation_job.rb" => "internal request label",
    "app/jobs/manual_agent_response_job.rb" => "internal request label",
    "app/jobs/safeguard_weekly_digest_job.rb" => "digest copy",
    "app/controllers/agents_controller.rb" => "orientation request copy",
    "app/controllers/admin/notices_controller.rb" => "admin notice template copy",
    "app/controllers/api/v1/safeguard_reclaims_controller.rb" => "internal request label",
    "app/controllers/api/v1/telegram_messages_controller.rb" => "Telegram sender_name copy",
    "app/services/safeguard_notice_renderer.rb" => "safeguard notice copy",
    "app/models/agent_runtime_interaction/live_activity.rb" => "internal request label",
    "app/frontend/lib/branding.js" => "site branding copy",
    "app/frontend/lib/components/admin/SiteIdentitySettingsCard.svelte" => "admin settings page copy",
    "app/frontend/lib/components/navigation/Footer.svelte" => "footer copy",
    "app/frontend/pages/safeguard-responses.svelte" => "public safeguard-explanation page copy",
    "app/frontend/pages/self-host.svelte" => "self-host page copy",
    "app/frontend/pages/self-host-technical.svelte" => "self-host page copy",
    "app/frontend/pages/home.svelte" => "marketing page copy",
    "app/frontend/pages/privacy.svelte" => "privacy page copy",
    "app/frontend/pages/terms.svelte" => "terms page copy",
    "app/frontend/pages/accounts/agent_api_keys.svelte" => "settings page copy",
    "app/views/user_mailer/confirmation.text.erb" => "email copy",
    "app/views/user_mailer/confirmation.html.erb" => "email copy",
    "app/views/pwa/manifest.json.erb" => "PWA manifest short_name/name",
    "app/assets/images/souls-house-logo.svg" => "logo asset metadata"
  }.freeze

  test "no forbidden upstream identifiers outside house.env" do
    offenders = []
    scan_files.each do |path|
      relative = relative_path(path)
      next if FORBIDDEN_STRING_ALLOWLIST.key?(relative)
      content = read(path)
      FORBIDDEN_STRINGS.each do |needle|
        offenders << "#{relative}: #{needle.inspect}" if content.include?(needle)
      end
    end
    assert_empty offenders,
      "Upstream identifiers found outside config/house.env(.example) — " \
      "add SOULSHOUSE_*/HOUSE_* env indirection, or extend " \
      "FORBIDDEN_STRING_ALLOWLIST if this is a deliberate legacy reference:\n#{offenders.join("\n")}"
  end

  test "souls.house only appears in the allowlist" do
    offenders = []
    scan_files.each do |path|
      relative = relative_path(path)
      next if SOULS_HOUSE_ALLOWLIST.key?(relative)
      offenders << relative if read(path).include?("souls.house")
    end
    assert_empty offenders,
      "\"souls.house\" found outside SOULS_HOUSE_ALLOWLIST — make it " \
      "env-driven, or add it to the allowlist with a reason:\n#{offenders.join("\n")}"
  end

  test "souls.house allowlist has no stale entries" do
    stale = SOULS_HOUSE_ALLOWLIST.keys.reject do |relative|
      path = Rails.root.join(relative)
      path.file? && read(path).include?("souls.house")
    end
    assert_empty stale, "Allowlist entries whose file is gone or no longer mentions souls.house: #{stale.join(', ')}"
  end

  test "forbidden-string allowlist has no stale entries" do
    stale = FORBIDDEN_STRING_ALLOWLIST.keys.reject do |relative|
      path = Rails.root.join(relative)
      path.file? && FORBIDDEN_STRINGS.any? { |needle| read(path).include?(needle) }
    end
    assert_empty stale, "Allowlist entries whose file is gone or no longer contains a forbidden string: #{stale.join(', ')}"
  end

  private

  def scan_files
    SCAN_ROOTS.flat_map { |root| Dir.glob("#{Rails.root.join(root)}/**/*") }
      .map { |path| Pathname.new(path) }
      .select(&:file?)
      .reject { |path| excluded?(path) }
  end

  def excluded?(path)
    relative = relative_path(path)
    return true if EXCLUDED_FILES.include?(relative)
    EXCLUDED_DIR_PREFIXES.any? { |prefix| relative.start_with?(prefix) }
  end

  def relative_path(path)
    path.relative_path_from(Rails.root).to_s
  end

  # Byte-safe: some scanned files aren't UTF-8 clean, and we're only ever
  # looking for plain ASCII needles.
  def read(path)
    File.binread(path)
  end

end
