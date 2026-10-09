# Every five minutes: the house host (load, CPU, memory, disk, and CPU and
# memory per resident container) and the CPU of each Hetzner VM we run.
class HouseHostSampleJob < ApplicationJob

  queue_as :default
  limits_concurrency to: 1, key: "house_host_sample", duration: 4.minutes

  def perform(now: Time.current)
    sample_house(now)
    sample_hetzner(now)
    HouseSample.prune!(now:)
  end

  private

  def sample_house(now)
    previous = HouseSample.of_kind("host").where(subject: "house", sampled_at: (now - 15.minutes)..)
                          .order(sampled_at: :desc).first
    metrics = HouseSampling::HostReader.new.call(previous: previous&.metrics)
    metrics["residents"] = HouseSampling::ContainerStats.new.call
    HouseSample.create!(kind: "host", subject: "house", sampled_at: now, metrics:)
  end

  # Hetzner reports CPU as percent of one vCPU, averaged over each step.
  def sample_hetzner(now)
    placements = AgentPlacement.where(backend: "hetzner_cloud").where.not(provider_server_id: nil)
    return if placements.none?
    client = HetznerCloudClient.from_credentials
    placements.find_each do |placement|
      cpu = client.server_cpu(placement.provider_server_id, start: now - 5.minutes, finish: now)
      HouseSample.create!(kind: "hetzner_vm", subject: "hetzner:#{placement.provider_server_id}",
        agent_id: placement.agent_id, sampled_at: now, metrics: { "cpu_percent" => cpu, "location" => placement.location })
    rescue HetznerCloudClient::Error => e
      Rails.logger.warn("Hetzner CPU sample failed for #{placement.provider_server_id}: #{e.message}")
    end
  rescue HetznerCloudClient::Error => e
    Rails.logger.warn("Hetzner CPU sampling skipped: #{e.message}")
  end

end
