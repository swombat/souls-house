require "net/http"
require "json"

# What is running, and what is merged, for the site-admin menu.
#
# The deployed revision comes from the container itself: Kamal sets
# KAMAL_VERSION to the git sha the image was built from. GitHub is only
# asked about master, so a slow or failed GitHub call can make the menu
# say "unknown", but can never make it claim something is live.
class DeployInfo

  SHA = /\A(\h{7,40})(_.+)?\z/
  DEFAULT_REPO = "swombat/souls-house"
  CACHE_TTL = 5.minutes
  TIMEOUT = 3

  class_attribute :fetcher, default: ->(path) { DeployInfo.github_get(path) }

  def self.booted_at
    Rails.application.config.x.booted_at
  end

  def self.repo
    ENV["HOUSE_SOURCE_REPO"].presence || DEFAULT_REPO
  end

  def self.summary(version: ENV["KAMAL_VERSION"])
    new(version:).summary
  end

  def self.github_get(path)
    uri = URI("https://api.github.com#{path}")
    request = Net::HTTP::Get.new(uri)
    request["Accept"] = "application/vnd.github+json"
    request["X-GitHub-Api-Version"] = "2022-11-28"
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.request(request)
    end
    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def initialize(version:)
    @version = version.to_s
  end

  def summary
    deployed = deployed_commit
    master = master_commit
    {
      repo: self.class.repo,
      deployed: deployed,
      master: master,
      behind_by: behind_by(deployed, master)
    }
  end

  private

  def deployed_commit
    match = SHA.match(@version)
    return nil unless match

    {
      sha: match[1],
      short: match[1].first(7),
      dirty: match[2].present?,
      booted_at: self.class.booted_at&.iso8601
    }
  end

  def master_commit
    data = cached("master") { fetch("/repos/#{self.class.repo}/commits/master") }
    return nil unless data.is_a?(Hash) && data["sha"].is_a?(String)

    {
      sha: data["sha"],
      short: data["sha"].first(7),
      committed_at: data.dig("commit", "committer", "date"),
      message: data.dig("commit", "message").to_s.lines.first.to_s.strip.truncate(80)
    }
  end

  # How many master commits the running build is missing. nil means "can't
  # say": no deployed sha, an uncommitted build, GitHub unreachable, or a
  # build that isn't an ancestor of master.
  def behind_by(deployed, master)
    return nil unless deployed && master && !deployed[:dirty]
    return 0 if master[:sha].start_with?(deployed[:sha])

    data = cached("compare:#{deployed[:sha]}:#{master[:sha]}") do
      fetch("/repos/#{self.class.repo}/compare/#{deployed[:sha]}...#{master[:sha]}")
    end
    return nil unless data.is_a?(Hash)

    case data["status"]
    when "identical" then 0
    when "ahead" then data["ahead_by"].to_i
    end
  end

  def cached(key, &block)
    Rails.cache.fetch("deploy_info:#{self.class.repo}:#{key}", expires_in: CACHE_TTL, skip_nil: true, &block)
  end

  def fetch(path)
    fetcher.call(path)
  rescue StandardError => e
    Rails.logger.warn("[DeployInfo] #{path}: #{e.class}: #{e.message}")
    nil
  end

end
