require "net/http"
require "json"

# Whether commits mentioned in chat are live, on master, or neither.
#
#   deployed  an ancestor of (or equal to) the revision this container runs
#   merged    on master but not in the running revision
#   unmerged  exists in the repo but is not on master
#   nil       unknown: not found, ambiguous, GitHub unreachable, rate limited
#
# "Deployed" is measured against the running container (KAMAL_VERSION), so it
# follows rollbacks. Each answer is built from ancestry facts between two full
# shas, and those never change, so they are cached for a long time; the
# current master and running revision are part of every key. Failures are
# never cached, so a GitHub outage stays "unknown" instead of becoming "no".
class CommitStatus

  CANDIDATE = /\A\h{7,40}\z/
  MAX_SHAS = 50
  MAX_LOOKUPS = 20
  FACT_TTL = 30.days
  MISSING_TTL = 1.hour
  TIMEOUT = 3

  class_attribute :fetcher, default: ->(path) { CommitStatus.github_get(path) }

  # Returns [http_status, parsed_body]; raises on network failure.
  def self.github_get(path)
    uri = URI("https://api.github.com#{path}")
    request = Net::HTTP::Get.new(uri)
    request["Accept"] = "application/vnd.github+json"
    request["X-GitHub-Api-Version"] = "2022-11-28"
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.request(request)
    end
    body = response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body) : nil
    [ response.code.to_i, body ]
  end

  def self.lookup(shas, summary: DeployInfo.summary)
    new(summary).lookup(shas)
  end

  def initialize(summary)
    @repo = summary[:repo]
    deployed = summary[:deployed]
    @deployed = deployed[:sha] if deployed && !deployed[:dirty] && deployed[:sha].length == 40
    @master = summary.dig(:master, :sha)
    @lookups = 0
  end

  def lookup(shas)
    candidates = Array(shas).map { |sha| sha.to_s.downcase }.select { |sha| sha.match?(CANDIDATE) }.uniq.first(MAX_SHAS)
    candidates.to_h { |sha| [ sha, status_for(sha) ] }
  end

  private

  def status_for(sha)
    live = ancestor_of?(sha, @deployed)
    return "deployed" if live
    # A failed live check must not fall through to "merged", which would
    # read as "not deployed". Only a build with no revision skips it.
    return nil if live.nil? && @deployed

    case ancestor_of?(sha, @master)
    when true then "merged"
    when false then "unmerged"
    end
  end

  # true / false when GitHub answered for exactly this commit; nil otherwise.
  def ancestor_of?(sha, target)
    return nil unless target
    return true if target.start_with?(sha)

    fact = cached_fact(sha, target)
    fact.is_a?(Hash) ? fact["ancestor"] : nil
  end

  def cached_fact(sha, target)
    key = "commit_status:#{@repo}:#{sha}:#{target}"
    cached = Rails.cache.read(key)
    return cached unless cached.nil?
    return nil if @lookups >= MAX_LOOKUPS

    @lookups += 1
    fact = compare(sha, target)
    case fact
    when :missing then Rails.cache.write(key, { "ancestor" => nil }, expires_in: MISSING_TTL)
    when Hash then Rails.cache.write(key, fact, expires_in: FACT_TTL)
    end
    fact.is_a?(Hash) ? fact : nil
  end

  # compare/BASE...HEAD: "ahead" or "identical" means BASE is an ancestor of
  # HEAD. A short sha that matches nothing, or more than one commit, is not
  # resolved by GitHub (404/422), so it stays unknown and gets no badge.
  def compare(sha, target)
    code, data = fetcher.call("/repos/#{@repo}/compare/#{sha}...#{target}")
    return :missing if [ 404, 422 ].include?(code)
    return nil unless code == 200 && data.is_a?(Hash)

    base = data.dig("base_commit", "sha").to_s
    return nil unless base.length == 40 && base.start_with?(sha)

    case data["status"]
    when "ahead", "identical" then { "ancestor" => true, "sha" => base }
    when "behind", "diverged" then { "ancestor" => false, "sha" => base }
    end
  rescue StandardError => e
    Rails.logger.warn("[CommitStatus] #{sha}...#{target}: #{e.class}: #{e.message}")
    nil
  end

end
