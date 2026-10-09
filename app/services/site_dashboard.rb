# Everything the site admin dashboard shows, computed from what the house
# already records. Founding and family accounts (Account#founding) are kept
# out of the growth numbers and costed as their own band.
#
# Server and storage measurements that need sampling (CPU, disk, Restic bytes
# actually stored in S3) arrive through HostSample/StorageSample; until those
# exist the dashboard says so instead of drawing zeros.
class SiteDashboard

  DAYS = 30
  WEEKS = 26
  HOURS = 7 * 24
  GIB = 1024**3
  CACHE_KEY = "admin/site_dashboard/v1".freeze
  # A finished turn failed if the runtime said error or timeout, if the live
  # activity path finished it as failed or timed out, or if the house
  # recorded an error and the runtime never reported a status (a refused or
  # dropped connection). "busy" (409 already_running) is a conflict, not a
  # failure, and cancellations are not counted either.
  FAILED_SQL = <<~SQL.squish.freeze
    (agent_runtime_interactions.runtime_status IN ('error', 'timeout')
      OR agent_runtime_interactions.execution_state IN ('failed', 'timed_out')
      OR (agent_runtime_interactions.runtime_status IS NULL AND agent_runtime_interactions.error_class IS NOT NULL))
  SQL

  def self.expire_cache!
    Rails.cache.delete(CACHE_KEY)
  end

  CHANNELS = {
    "conversation" => "Conversations",
    "telegram" => "Telegram",
    "wake" => "Heartbeats",
    "memory" => "Memory",
    "other" => "Other"
  }.freeze

  def self.channel_for(trigger_kind)
    case trigger_kind
    when "conversation" then "conversation"
    when "telegram" then "telegram"
    when "wake" then "wake"
    when /\Amemory_aggregation_/ then "memory"
    else "other"
    end
  end

  def initialize(now: Time.current)
    @now = now
    @today = now.to_date
  end

  def call
    {
      generated_at: now.iso8601,
      headline: headline,
      growth: growth,
      funnel: funnel,
      activity: activity,
      reliability: reliability,
      costs: costs,
      placement: placement,
      backups: backups,
      server: server,
      storage: storage,
      founding: founding_accounts
    }
  end

  private

  attr_reader :now, :today

  # --- cohorts -------------------------------------------------------------

  def founding_ids
    @founding_ids ||= Account.where(founding: true).pluck(:id)
  end

  def public_accounts
    Account.where.not(id: founding_ids)
  end

  def public_agents
    Agent.where.not(account_id: founding_ids)
  end

  def founding_agents
    Agent.where(account_id: founding_ids)
  end

  # A human belongs to the founding band if any of their accounts does.
  def founding_user_ids
    @founding_user_ids ||= Membership.where(account_id: founding_ids).distinct.pluck(:user_id)
  end

  def public_users
    User.where.not(id: founding_user_ids)
  end

  def public_agent_ids
    @public_agent_ids ||= public_agents.pluck(:id)
  end

  # --- headline -------------------------------------------------------------

  def headline
    week_ago = 7.days.ago(now)
    two_weeks_ago = 14.days.ago(now)
    {
      accounts: count_with_delta(public_accounts, week_ago),
      humans: count_with_delta(public_users, week_ago),
      residents: count_with_delta(public_agents.active, week_ago),
      active_residents: {
        value: active_agent_ids(since: week_ago, agent_ids: public_agent_ids).size,
        previous: active_agent_ids(since: two_weeks_ago, until_time: week_ago, agent_ids: public_agent_ids).size
      },
      active_humans: {
        value: active_user_count(since: week_ago),
        previous: active_user_count(since: two_weeks_ago, until_time: week_ago)
      },
      founding: {
        accounts: founding_ids.size,
        residents: founding_agents.active.count
      }
    }
  end

  def count_with_delta(scope, since)
    { value: scope.count, added: scope.where(created_at: since..).count }
  end

  def active_agent_ids(since:, agent_ids:, until_time: now)
    AgentRuntimeInteraction.where(agent_id: agent_ids, started_at: since...until_time).distinct.pluck(:agent_id)
  end

  def active_user_count(since:, until_time: now)
    Message.where(role: "user", created_at: since...until_time)
           .where.not(user_id: nil).where.not(user_id: founding_user_ids)
           .distinct.count(:user_id)
  end

  # --- growth (weekly, cumulative) -----------------------------------------

  def growth
    start = (WEEKS - 1).weeks.ago(now).beginning_of_week
    weeks = (0...WEEKS).map { |i| (start + i.weeks).to_date }
    {
      weeks: weeks.map(&:iso8601),
      accounts: cumulative(public_accounts, weeks, start),
      humans: cumulative(public_users, weeks, start),
      residents: cumulative(public_agents, weeks, start)
    }
  end

  def cumulative(scope, weeks, start)
    base = scope.where(created_at: ...start).count
    per_week = scope.where(created_at: start..)
                    .group(Arel.sql("date_trunc('week', #{scope.table_name}.created_at)"))
                    .count
                    .transform_keys { |time| time.to_date }
    running = base
    weeks.map do |week|
      running += per_week.fetch(week, 0)
      running
    end
  end

  # --- funnel ---------------------------------------------------------------

  # Registered → made a resident → that resident has answered someone.
  def funnel
    users = public_users
    with_resident = users.joins(memberships: { account: :agents }).distinct
    conversed_agent_ids = AgentRuntimeInteraction.where(agent_id: public_agent_ids, trigger_kind: %w[conversation telegram])
                                                 .distinct.select(:agent_id)
    in_conversation = users.joins(memberships: { account: :agents })
                           .where(agents: { id: conversed_agent_ids }).distinct
    recent = 30.days.ago(now)
    {
      all_time: [ users.count, with_resident.count, in_conversation.count ],
      last_30_days: [
        users.where(created_at: recent..).count,
        with_resident.where(created_at: recent..).count,
        in_conversation.where(created_at: recent..).count
      ]
    }
  end

  # --- activity (daily turns by channel) -----------------------------------

  def days
    @days ||= (0...DAYS).map { |i| today - (DAYS - 1 - i) }
  end

  def interactions_window
    AgentRuntimeInteraction.where(started_at: days.first.beginning_of_day..)
  end

  def activity
    rows = interactions_window
           .group(Arel.sql("date_trunc('day', started_at)"), :trigger_kind, Arel.sql("agent_id IN (#{agent_id_list(public_agent_ids)})"))
           .count
    everyone = Hash.new { |hash, key| hash[key] = Array.new(DAYS, 0) }
    growth_only = Hash.new { |hash, key| hash[key] = Array.new(DAYS, 0) }
    index = days.each_with_index.to_h
    rows.each do |(day, kind, is_public), count|
      position = index[day.to_date]
      next unless position
      channel = self.class.channel_for(kind)
      everyone[channel][position] += count
      growth_only[channel][position] += count if is_public
    end
    {
      days: days.map(&:iso8601),
      channels: CHANNELS.map { |key, label| { key:, label: } },
      everyone: CHANNELS.keys.index_with { |key| everyone[key] },
      growth: CHANNELS.keys.index_with { |key| growth_only[key] }
    }
  end

  def agent_id_list(ids)
    ids.any? ? ids.map(&:to_i).join(",") : "NULL"
  end

  # --- reliability ----------------------------------------------------------

  def reliability
    week = AgentRuntimeInteraction.where(started_at: 7.days.ago(now)..).where.not(finished_at: nil)
    finished = week.count
    failed_scope = week.where(FAILED_SQL)
    failed = failed_scope.count
    daily = interactions_window.where.not(finished_at: nil)
                               .group(Arel.sql("date_trunc('day', started_at)"))
                               .pluck(Arel.sql("date_trunc('day', started_at)"), Arel.sql("count(*)"),
                                      Arel.sql("count(*) FILTER (WHERE #{FAILED_SQL})"))
                               .to_h { |day, total, bad| [ day.to_date, [ total, bad ] ] }
    # Several trigger kinds share a channel (memory_aggregation_daily and
    # _weekly are both "memory"), so sum into the channel rather than
    # re-keying, which would keep only the last kind's count.
    by_channel = Hash.new(0)
    failed_scope.group(:trigger_kind).count.each { |kind, count| by_channel[self.class.channel_for(kind)] += count }
    backup_week = AgentBackupSnapshot.where(taken_at: 7.days.ago(now)..)
    {
      turns_finished: finished,
      turns_failed: failed,
      failure_rate: finished.zero? ? nil : (failed.to_f / finished).round(4),
      failure_rate_daily: days.map { |day| total, bad = daily[day]; total.to_i.zero? ? nil : (bad.to_f / total).round(4) },
      failures_by_kind: by_channel.to_h,
      backups_taken: backup_week.count,
      backups_failed: backup_week.where(ok: false).count,
      oldest_open_failure_at: oldest_open_backup_failure
    }
  end

  # A resident whose most recent backup failed is an open failure; report the
  # oldest such failure so a stuck resident is visible at a glance.
  def oldest_open_backup_failure
    latest = latest_snapshots
    latest.reject(&:ok).min_by(&:taken_at)&.taken_at&.iso8601
  end

  def latest_snapshots
    @latest_snapshots ||= AgentBackupSnapshot
                          .select("DISTINCT ON (agent_id) agent_backup_snapshots.*")
                          .order(:agent_id, taken_at: :desc)
                          .to_a
  end

  # --- costs ----------------------------------------------------------------

  # Estimated model spend for the last 30 days, split into the public band and
  # the founding band. Subscription-backed turns cost nothing at the margin;
  # they are shown as an estimate of what they would have cost on an API key.
  def costs
    bands = {
      public: cost_band,
      founding: cost_band
    }
    public_ids = public_agent_ids.to_set
    scope = interactions_window.select(cost_columns)
    scope.find_each do |interaction|
      estimate = interaction.estimated_cost
      band = bands[public_ids.include?(interaction.agent_id) ? :public : :founding]
      amount = estimate[:amount_usd]
      unless amount
        band[:unpriced] += 1
        next
      end
      position = days.index(interaction.started_at.to_date)
      if interaction.subscription_based?
        band[:subscription_estimate] += BigDecimal(amount)
      else
        band[:api] += BigDecimal(amount)
        band[:daily][position] += BigDecimal(amount) if position
      end
    end
    active_public = active_agent_ids(since: days.first.beginning_of_day, agent_ids: public_agent_ids).size
    active_founding = active_agent_ids(since: days.first.beginning_of_day, agent_ids: founding_agents.pluck(:id)).size
    {
      window_days: DAYS,
      pricing_as_of: AgentRuntimeInteractionCost::UPDATED_PRICING_AS_OF.iso8601,
      public: present_band(bands[:public], active_public),
      founding: present_band(bands[:founding], active_founding)
    }
  end

  def cost_band
    { api: BigDecimal("0"), subscription_estimate: BigDecimal("0"), unpriced: 0, daily: Array.new(DAYS) { BigDecimal("0") } }
  end

  def present_band(band, active)
    {
      api_usd: band[:api].round(2).to_f,
      subscription_estimate_usd: band[:subscription_estimate].round(2).to_f,
      unpriced_turns: band[:unpriced],
      active_residents: active,
      per_active_resident_usd: active.zero? ? nil : (band[:api] / active).round(2).to_f,
      daily_usd: band[:daily].map { |value| value.round(4).to_f }
    }
  end

  def cost_columns
    # What AgentRuntimeInteractionCost reads, without the large text columns.
    %i[id agent_id started_at model provider provider_auth_mode output_tokens
       uncached_input_tokens cache_creation_input_tokens cache_read_input_tokens
       telemetry_schema_version usage_scope cache_ttl]
  end

  # --- placement ------------------------------------------------------------

  def placement
    agents = Agent.active.left_joins(:placement)
    rows = agents.group(Arel.sql("COALESCE(agent_placements.backend, 'local')"),
                        Arel.sql("COALESCE(agent_placements.location, '')"),
                        Arel.sql("agents.account_id IN (#{agent_id_list(founding_ids)})"))
                 .count
    groups = rows.map do |(backend, location, founding), count|
      { backend:, location: location.presence, founding: !!founding, residents: count }
    end
    # Only a provisioned operation with a provider server is a VM we know
    # exists. "unknown" means a purchase may exist but none is visible, so
    # anything unresolved is reported separately, never counted as a VM.
    confirmed = CloudProcurementOperation.where(state: "provisioned").where.not(provider_server_id: nil)
    unresolved = CloudProcurementOperation.where(state: %w[planned create_in_flight reconciling unknown needs_review deleting])
                                          .or(CloudProcurementOperation.where(state: "provisioned", provider_server_id: nil))
    {
      groups: groups.sort_by { |row| [ row[:backend], row[:location].to_s, row[:founding] ? 1 : 0 ] },
      vms: confirmed.group(:server_type, :location).count.map { |(type, location), count| { server_type: type, location:, count: } },
      unresolved_procurements: unresolved.group(:state).count
    }
  end

  # --- backups --------------------------------------------------------------

  def backups
    # Size from each resident's last good snapshot: a resident whose newest
    # attempt failed still has its earlier backup in the repository.
    latest = AgentBackupSnapshot.where(ok: true)
                                .select("DISTINCT ON (agent_id) agent_backup_snapshots.*")
                                .order(:agent_id, taken_at: :desc)
                                .to_a
    agents = Agent.where(id: latest.map(&:agent_id)).index_by(&:id)
    founding = founding_ids.to_set
    rows = latest.filter_map do |snapshot|
      agent = agents[snapshot.agent_id]
      next unless agent
      { name: agent.name, founding: founding.include?(agent.account_id), bytes: snapshot.size_bytes.to_i,
        taken_at: snapshot.taken_at.iso8601 }
    end
    {
      logical_bytes: rows.sum { |row| row[:bytes] },
      residents_backed_up: rows.size,
      largest: rows.sort_by { |row| -row[:bytes] }.first(8),
      daily_logical_bytes: daily_backup_totals
    }
  end

  # Total backed-up bytes at the end of each day, carrying each resident's
  # last good snapshot forward so a resident backed up weekly still counts.
  def daily_backup_totals
    start = days.first.beginning_of_day
    before = AgentBackupSnapshot.where(ok: true, taken_at: ...start)
                                .select("DISTINCT ON (agent_id) agent_id, size_bytes, taken_at")
                                .order(:agent_id, taken_at: :desc)
    during = AgentBackupSnapshot.where(ok: true, taken_at: start..).order(:taken_at).pluck(:agent_id, :size_bytes, :taken_at)
    carry_forward(before.to_h { |row| [ row.agent_id, row.size_bytes.to_i ] }, during)
  end

  # Daily totals from per-resident readings, each resident's last reading
  # carried forward until a newer one arrives. `during` is [[id, bytes, time]]
  # sorted by time.
  def carry_forward(current, during)
    pointer = 0
    days.map do |day|
      limit = day.end_of_day
      while pointer < during.size && during[pointer][2] <= limit
        agent_id, bytes, = during[pointer]
        current[agent_id] = bytes.to_i
        pointer += 1
      end
      total = current.values.sum
      total.positive? ? total : nil
    end
  end

  # --- server (sampled every five minutes) ---------------------------------

  def host_samples
    HouseSample.of_kind("host").where(subject: "house")
  end

  def server
    latest = host_samples.order(sampled_at: :desc).first
    return { available: false } unless latest
    metrics = latest.metrics
    hours = (0...HOURS).map { |i| (now - (HOURS - 1 - i).hours).beginning_of_hour }
    hourly = host_samples.where(sampled_at: hours.first..)
                         .group(Arel.sql("date_trunc('hour', sampled_at)"))
                         .pluck(Arel.sql("date_trunc('hour', sampled_at)"),
                                Arel.sql("avg((metrics->>'cpu_percent')::float)"),
                                Arel.sql("avg((metrics->>'load_1')::float)"),
                                Arel.sql("avg((metrics->>'mem_total_bytes')::float - (metrics->>'mem_available_bytes')::float)"))
                         .to_h { |hour, cpu, load, mem| [ hour.to_i, [ cpu&.round(1), load&.round(2), mem&.round ] ] }
    series = hours.map { |hour| hourly[hour.to_i] || [ nil, nil, nil ] }
    disk_daily = host_samples.where(sampled_at: days.first.beginning_of_day..)
                             .group(Arel.sql("date_trunc('day', sampled_at)"))
                             .maximum(Arel.sql("(metrics->>'disk_used_bytes')::bigint"))
                             .transform_keys(&:to_date)
    day_cpu = host_samples.where(sampled_at: 24.hours.ago(now)..).average(Arel.sql("(metrics->>'cpu_percent')::float"))
    {
      available: true,
      sampled_at: latest.sampled_at.iso8601,
      cores: metrics["cores"],
      load: [ metrics["load_1"], metrics["load_5"], metrics["load_15"] ],
      cpu_percent: metrics["cpu_percent"],
      cpu_avg_24h: day_cpu&.to_f&.round(1),
      mem_total_bytes: metrics["mem_total_bytes"],
      mem_available_bytes: metrics["mem_available_bytes"],
      disk_total_bytes: metrics["disk_total_bytes"],
      disk_used_bytes: metrics["disk_used_bytes"],
      hourly_cpu: series.map(&:first),
      hourly_load: series.map { |row| row[1] },
      hourly_mem_used: series.map(&:last),
      daily_disk_used: days.map { |day| disk_daily[day] },
      busiest_residents: busiest_residents,
      vms: hetzner_vms
    }
  end

  # Average CPU (percent of one core) and memory per resident container over
  # the last 24 hours, from the per-container readings in each host sample.
  def busiest_residents
    rows = HouseSample.connection.select_rows(HouseSample.sanitize_sql([ <<~SQL.squish, 24.hours.ago(now) ]))
      SELECT entry.key, avg((entry.value->>'cpu')::float), avg((entry.value->>'mem')::float)
      FROM house_samples, jsonb_each(house_samples.metrics->'residents') AS entry
      WHERE house_samples.kind = 'host' AND house_samples.subject = 'house' AND house_samples.sampled_at >= ?
      GROUP BY entry.key ORDER BY 2 DESC NULLS LAST LIMIT 8
    SQL
    agents = Agent.where(id: rows.map { |row| row.first.to_i }).index_by(&:id)
    founding = founding_ids.to_set
    rows.filter_map do |agent_id, cpu, mem|
      agent = agents[agent_id.to_i]
      next unless agent
      { name: agent.name, founding: founding.include?(agent.account_id), cpu: cpu.to_f.round(1), mem_bytes: mem&.to_f&.round }
    end
  end

  def hetzner_vms
    latest = HouseSample.latest_per(:subject, "hetzner_vm").where(sampled_at: 1.hour.ago(now)..).to_a
    agents = Agent.where(id: latest.map(&:agent_id)).index_by(&:id)
    latest.map do |sample|
      { name: agents[sample.agent_id]&.name, location: sample.metrics["location"], cpu: sample.metrics["cpu_percent"] }
    end
  end

  # --- storage: on disk vs in Restic, and what it costs ---------------------

  def storage
    pricing = HouseSample.of_kind("pricing").order(sampled_at: :desc).first&.metrics || {}
    restic = HouseSample.latest_per(:agent_id, "restic_storage").to_a
    # The hourly du measurement; an "unavailable" refresh keeps the last bytes.
    on_disk = Agent.hosted.pluck(:storage_usage).select { |usage| usage["bytes"].present? }
    stored = restic.sum { |sample| sample.metrics["bytes"].to_i }
    price = pricing["s3_usd_per_gb_month"]
    {
      restic_sampled: restic.any?,
      restic_stored_bytes: restic.any? ? stored : nil,
      restic_objects: restic.sum { |sample| sample.metrics["objects"].to_i },
      restic_usd_per_month: restic.any? && price ? (stored.to_f / GIB * price).round(2) : nil,
      s3_usd_per_gb_month: price,
      s3_region: pricing["s3_region"],
      restic_daily_bytes: daily_sample_totals("restic_storage"),
      disk_bytes: on_disk.any? ? on_disk.sum { |usage| usage["bytes"].to_i } : nil,
      disk_residents_measured: on_disk.size,
      disk_daily_bytes: daily_sample_totals("resident_disk"),
      hetzner_eur_per_month: hetzner_monthly(pricing["hetzner_eur_per_month"])
    }
  end

  def daily_sample_totals(kind)
    start = days.first.beginning_of_day
    before = HouseSample.latest_per(:agent_id, kind).where(sampled_at: ...start).to_a
                        .to_h { |sample| [ sample.agent_id, sample.metrics["bytes"].to_i ] }
    during = HouseSample.of_kind(kind).where(sampled_at: start..).order(:sampled_at)
                        .pluck(:agent_id, Arel.sql("(metrics->>'bytes')::bigint"), :sampled_at)
    carry_forward(before, during)
  end

  def hetzner_monthly(prices)
    return nil unless prices.is_a?(Hash)
    # Confirmed VMs only, as in #placement: an unresolved purchase is not a cost we know we pay.
    vms = CloudProcurementOperation.where(state: "provisioned").where.not(provider_server_id: nil)
                                   .pluck(:server_type, :location)
    return 0.0 if vms.empty?
    amounts = vms.map { |type, location| prices.dig(type, location) }
    return nil if amounts.any?(&:nil?)
    amounts.sum.round(2)
  end

  # --- founding -------------------------------------------------------------

  def founding_accounts
    Account.where(founding: true).order(:name).map do |account|
      { id: account.to_param, name: account.name, residents: account.agents.active.count }
    end
  end

end
