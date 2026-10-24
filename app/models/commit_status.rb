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
# follows rollbacks. Only the house's own repository has a running revision;
# an account's repository (CommitBadges) is measured against its default
# branch alone, with tracks_deploys: false, and so is only ever merged or
# unmerged. Without a clean, full running revision nothing can be
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
  NO_SUCH_COMMIT = "No commit found for SHA"
  # An account's repository is measured against its default branch, whatever
  # it is called, and never for deployment, so its answers have their own
  # names rather than borrowing the house's "merged" (on master, not deployed).
  DEFAULT_BRANCH_STATUSES = { "merged" => "on_default", "unmerged" => "off_default" }.freeze
  TIMEOUT = 3

  # ->(path, token: nil) { [code, body] }
  class_attribute :fetcher, default: ->(path, token: nil) { CommitStatus.github_get(path, token:) }

  # Returns [http_status, parsed_body]; raises on network failure. A token
  # reaches private repositories and the authenticated rate limit. An error's
  # JSON body is kept too: telling "No commit found for SHA" (a readable
  # repository without the commit) from other 422s depends on its message.
  # A body that isn't JSON is nil.
  def self.github_get(path, token: nil)
    uri = URI("https://api.github.com#{path}")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{token}" if token.present?
    request["Accept"] = "application/vnd.github+json"
    request["X-GitHub-Api-Version"] = "2022-11-28"
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.request(request)
    end
    [ response.code.to_i, parse_body(response) ]
  end

  def self.parse_body(response)
    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    raise if response.is_a?(Net::HTTPSuccess)

    nil
  end

  def self.lookup(shas, summary: DeployInfo.summary)
    new(summary).lookup(shas)
  end

  # The pair every answer is measured against; the browser drops its badges
  # when this changes.
  def self.revision(summary)
    [ summary.dig(:deployed, :sha), summary.dig(:master, :sha) ].join(":")
  end

  # fetcher: ->(path) { [code, body] }. cache_scope keeps one account's
  # answers about a private repository out of another account's cache.
  # confirm_full asks GitHub about full shas too, so that "this repository
  # has no such commit" can be told apart from "unknown" (CommitBadges needs
  # that to decide which of several repositories a bare sha belongs to).
  def initialize(summary, fetcher: self.class.fetcher, tracks_deploys: true, cache_scope: nil, confirm_full: false)
    @repo = summary[:repo]
    @tracks_deploys = tracks_deploys
    @deployed = full_sha(summary[:deployed]) if tracks_deploys && !summary.dig(:deployed, :dirty)
    @master = full_sha(summary[:master])
    @fetch = fetcher
    @cache_repo = cache_scope ? "#{cache_scope}:#{@repo}" : @repo
    @confirm_full = confirm_full
    @lookups = 0
  end

  def lookup(shas)
    candidates(shas).to_h { |sha| [ sha, status_for(sha) ] }
  end

  # sha => [presence, status]. presence is :found (this repository has the
  # commit), :missing (GitHub said it has no such commit) or nil (unknown).
  def probe(shas)
    candidates(shas).to_h do |sha|
      presence, full = resolution(sha)
      [ sha, [ presence, (full && status_of(full)) ] ]
    end
  end

  private

  def candidates(shas)
    Array(shas).map { |sha| sha.to_s.downcase }.select { |sha| sha.match?(CANDIDATE) }.uniq.first(MAX_SHAS)
  end

  def full_sha(commit)
    sha = commit.is_a?(Hash) ? commit[:sha].to_s.downcase : ""
    sha.match?(FULL) ? sha : nil
  end

  def status_for(sha)
    return nil unless measurable?

    full = resolve(sha)
    full && status_of(full)
  end

  def measurable?
    @master.present? && (@deployed.present? || !@tracks_deploys)
  end

  def status_of(full)
    return nil unless measurable?

    status = placement(full)
    status = landed_as(full) || status if status == "unmerged"
    @tracks_deploys ? status : DEFAULT_BRANCH_STATUSES[status]
  end

  def placement(full)
    if @tracks_deploys
      case ancestor_of?(full, @deployed)
      when true then return "deployed"
      when nil then return nil
      end
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
    key = "commit_status:merge_commit:#{@cache_repo}:#{full}"
    cached = Rails.cache.read(key)
    return cached.presence unless cached.nil?
    return nil unless budget?

    code, data = @fetch.call("/repos/#{@repo}/commits/#{full}/pulls")
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
    resolution(sha).last
  end

  # [presence, full sha]; see probe. Only GitHub's "No commit found for SHA"
  # (a 422 it gives only when it can read the repository) is proof that the
  # repository has no such commit. Any other 422 (an ambiguous prefix, say)
  # and every 404 (which is also what a repository the token can no longer
  # read looks like) stay unknown, and are not cached.
  def resolution(sha)
    return [ :found, sha ] if sha.match?(FULL) && !@confirm_full

    key = "commit_status:resolve:#{@cache_repo}:#{sha}"
    cached = Rails.cache.read(key)
    return (cached.present? ? [ :found, cached ] : [ :missing, nil ]) unless cached.nil?
    return [ nil, nil ] unless budget?

    code, data = @fetch.call("/repos/#{@repo}/commits/#{sha}")
    if no_such_commit?(code, data)
      Rails.cache.write(key, "", expires_in: MISSING_TTL)
      return [ :missing, nil ]
    end
    full = data.is_a?(Hash) ? data["sha"].to_s.downcase : ""
    return [ nil, nil ] unless code == 200 && full.match?(FULL) && full.start_with?(sha)

    Rails.cache.write(key, full, expires_in: RESOLUTION_TTL)
    [ :found, full ]
  rescue StandardError => e
    Rails.logger.warn("[CommitStatus] resolve #{sha}: #{e.class}: #{e.message}")
    [ nil, nil ]
  end

  def no_such_commit?(code, data)
    code == 422 && data.is_a?(Hash) && data["message"].to_s.start_with?(NO_SUCH_COMMIT)
  end

  # true / false when GitHub answered for exactly these two commits; nil otherwise.
  def ancestor_of?(full, target)
    return true if full == target

    key = "commit_status:ancestor:#{@cache_repo}:#{full}:#{target}"
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
    code, data = @fetch.call("/repos/#{@repo}/compare/#{full}...#{target}")
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
