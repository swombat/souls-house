require "net/http"
require "json"

# Whether commits mentioned in chat are live, on master, or neither.
#
#   deployed  an ancestor of (or equal to) the revision this container runs
#   merged    on master, and not in the revision this container runs
#   unmerged  exists in the repo but is not on master
#   nil       unknown: not found, ambiguous, GitHub unreachable, rate limited,
#             or the running revision itself is unknown
#
# A commit from a squash-merged pull request never reaches master itself;
# GitHub writes a new commit instead. So before calling a commit unmerged we
# ask GitHub whether it belongs to a merged pull request, and if it does, the
# commit takes the status of that pull request's merge commit.
#
# Two kinds of answer are kept apart:
#
# - Resolution: which full commit an abbreviation names. This can change (a
#   new commit can make a prefix ambiguous), so it is cached briefly, and an
#   abbreviation is only ever resolved by GitHub, never by prefix-matching.
# - Ancestry between two full shas. That never changes, so it is cached for
#   a long time, keyed by both full shas.
#
# "Deployed" is measured against the running container (KAMAL_VERSION), so it
# follows rollbacks. Without a clean, full running revision nothing can be
# said about deployment, and so nothing is said at all: "merged" claims the
# commit is not live, which would be a guess. Failures are never cached, so a
# GitHub outage stays "unknown" instead of becoming "no".
class CommitStatus

  CANDIDATE = /\A\h{7,40}\z/
  FULL = /\A\h{40}\z/
  MAX_SHAS = 50
  MAX_LOOKUPS = 20
  FACT_TTL = 30.days
  RESOLUTION_TTL = 1.hour
  MISSING_TTL = 10.minutes
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

  # The pair every answer is measured against; the browser drops its badges
  # when this changes.
  def self.revision(summary)
    [ summary.dig(:deployed, :sha), summary.dig(:master, :sha) ].join(":")
  end

  def initialize(summary)
    @repo = summary[:repo]
    @deployed = full_sha(summary[:deployed]) unless summary.dig(:deployed, :dirty)
    @master = full_sha(summary[:master])
    @lookups = 0
  end

  def lookup(shas)
    candidates = Array(shas).map { |sha| sha.to_s.downcase }.select { |sha| sha.match?(CANDIDATE) }.uniq.first(MAX_SHAS)
    candidates.to_h { |sha| [ sha, status_for(sha) ] }
  end

  private

  def full_sha(commit)
    sha = commit.is_a?(Hash) ? commit[:sha].to_s.downcase : ""
    sha.match?(FULL) ? sha : nil
  end

  def status_for(sha)
    return nil unless @deployed && @master

    full = resolve(sha)
    return nil unless full

    case (status = placement(full))
    when "unmerged" then landed_as(full) || status
    else status
    end
  end

  def placement(full)
    case ancestor_of?(full, @deployed)
    when true then return "deployed"
    when nil then return nil
    end

    case ancestor_of?(full, @master)
    when true then "merged"
    when false then "unmerged"
    end
  end

  # The status of the merge commit of a merged pull request containing this
  # commit, when it is on master; nil leaves the commit "unmerged".
  def landed_as(full)
    merge = merge_commit_for(full)
    return nil unless merge && merge != full

    status = placement(merge)
    status if %w[deployed merged].include?(status)
  end

  # A merged pull request's merge commit never changes, so it is kept for a
  # long time; "no merged pull request yet" can change, so only briefly.
  def merge_commit_for(full)
    key = "commit_status:merge_commit:#{@repo}:#{full}"
    cached = Rails.cache.read(key)
    return cached.presence unless cached.nil?
    return nil unless budget?

    code, data = fetcher.call("/repos/#{@repo}/commits/#{full}/pulls")
    return nil unless code == 200 && data.is_a?(Array)

    merge = data.filter_map { |pr| pr["merge_commit_sha"].to_s.downcase if pr.is_a?(Hash) && pr["merged_at"] }
      .find { |sha| sha.match?(FULL) }
    Rails.cache.write(key, merge.to_s, expires_in: merge ? FACT_TTL : MISSING_TTL)
    merge
  rescue StandardError => e
    Rails.logger.warn("[CommitStatus] pulls #{full}: #{e.class}: #{e.message}")
    nil
  end

  # The full sha an abbreviation names, or nil when GitHub didn't say it
  # names exactly one commit.
  def resolve(sha)
    return sha if sha.match?(FULL)

    key = "commit_status:resolve:#{@repo}:#{sha}"
    cached = Rails.cache.read(key)
    return cached.presence unless cached.nil?
    return nil unless budget?

    code, data = fetcher.call("/repos/#{@repo}/commits/#{sha}")
    if [ 404, 422 ].include?(code)
      Rails.cache.write(key, "", expires_in: MISSING_TTL)
      return nil
    end
    full = data.is_a?(Hash) ? data["sha"].to_s.downcase : ""
    return nil unless code == 200 && full.match?(FULL) && full.start_with?(sha)

    Rails.cache.write(key, full, expires_in: RESOLUTION_TTL)
    full
  rescue StandardError => e
    Rails.logger.warn("[CommitStatus] resolve #{sha}: #{e.class}: #{e.message}")
    nil
  end

  # true / false when GitHub answered for exactly these two commits; nil otherwise.
  def ancestor_of?(full, target)
    return true if full == target

    key = "commit_status:ancestor:#{@repo}:#{full}:#{target}"
    cached = Rails.cache.read(key)
    return cached unless cached.nil?
    return nil unless budget?

    answer = compare(full, target)
    Rails.cache.write(key, answer, expires_in: FACT_TTL) unless answer.nil?
    answer
  end

  # compare/BASE...HEAD between two full shas: "ahead" or "identical" means
  # BASE is an ancestor of HEAD.
  def compare(full, target)
    code, data = fetcher.call("/repos/#{@repo}/compare/#{full}...#{target}")
    return nil unless code == 200 && data.is_a?(Hash)
    return nil unless data.dig("base_commit", "sha").to_s.downcase == full

    case data["status"]
    when "ahead", "identical" then true
    when "behind", "diverged" then false
    end
  rescue StandardError => e
    Rails.logger.warn("[CommitStatus] #{full}...#{target}: #{e.class}: #{e.message}")
    nil
  end

  def budget?
    return false if @lookups >= MAX_LOOKUPS

    @lookups += 1
    true
  end

end
