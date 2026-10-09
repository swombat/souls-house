# Daily: disk used by each resident on the house host, bytes Restic stores in
# S3 for each resident, and the prices used to cost them.
class HouseStorageSampleJob < ApplicationJob

  queue_as :default
  limits_concurrency to: 1, key: "house_storage_sample", duration: 2.hours

  # S3 Standard list price, USD per GB-month, first 50 TB. eu-west-1 and
  # us-east-1 share it; other regions differ slightly. Shown on the dashboard
  # next to the cost so it can be corrected.
  S3_STANDARD_USD_PER_GB_MONTH = {
    "us-east-1" => 0.023, "us-east-2" => 0.023, "us-west-2" => 0.023, "eu-west-1" => 0.023
  }.freeze
  S3_FALLBACK_USD_PER_GB_MONTH = 0.023

  def perform(now: Time.current)
    sample_resident_disk(now)
    sample_restic(now)
    sample_pricing(now)
  end

  private

  # Reuses the hourly CollectAgentStorageUsageJob measurement (du of each
  # resident's volumes); this only keeps a daily history of it.
  def sample_resident_disk(now)
    Agent.hosted.find_each do |agent|
      usage = agent.storage_usage || {}
      next unless usage["status"].in?(%w[measured partial]) && usage["bytes"]
      HouseSample.create!(kind: "resident_disk", agent:, sampled_at: now,
        metrics: { "bytes" => usage["bytes"].to_i, "measured_at" => usage["measured_at"] })
    end
  end

  def sample_restic(now)
    reader = HouseSampling::ResticStorage.new
    return unless reader.enabled?
    Agent.where(id: AgentBackupSnapshot.select(:agent_id)).where.not(uuid: nil).find_each do |agent|
      HouseSample.create!(kind: "restic_storage", agent:, sampled_at: now, metrics: reader.call(agent))
    rescue StandardError => e
      Rails.logger.warn("Restic storage sample failed for agent #{agent.id}: #{e.class}")
    end
  end

  def sample_pricing(now)
    region = begin
      Backup::AgentRestic.region
    rescue ArgumentError, KeyError
      nil
    end
    known = S3_STANDARD_USD_PER_GB_MONTH.key?(region.to_s)
    metrics = {
      "s3_region" => region,
      "s3_usd_per_gb_month" => S3_STANDARD_USD_PER_GB_MONTH.fetch(region.to_s, S3_FALLBACK_USD_PER_GB_MONTH),
      # Not this region's verified price: the dashboard labels it an assumption.
      "s3_price_assumed" => !known
    }
    types = CloudProcurementOperation::SERVER_TYPES
    begin
      metrics["hetzner_eur_per_month"] = HetznerCloudClient.from_credentials.server_type_prices(types)
    rescue HetznerCloudClient::Error => e
      Rails.logger.warn("Hetzner price lookup skipped: #{e.message}")
    end
    HouseSample.create!(kind: "pricing", sampled_at: now, metrics:)
  end

end
