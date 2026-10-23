# Which repositories a reader's chat badges are measured against, and the
# answers for the commit references on their screen.
#
# Two kinds of source:
#
# - The house's own repository, for site admins only, exactly as before:
#   deployed, merged or unmerged against the running container and master.
# - Each repository the account has connected (WatchedRepository) with
#   commit badges switched on, for anyone in the account, read with that
#   GitHub connection's token. Nothing is known about what an account has
#   deployed, so these are only ever "on_default" or "off_default" (on its
#   default branch or not, whatever that branch is called); "deployed" and
#   "master" are never claimed for them.
#
# A reference is either a bare sha ("51625a7") or a sha named in a commit URL
# ("owner/name@51625a7"). A URL names its repository, so only that source is
# asked. A bare sha could belong to any of them, so it gets an answer only
# when exactly one source has the commit and every other source said it has
# no such commit; two repositories that both have it, or one that could not
# be asked, leave it without a badge rather than a guess.
class CommitBadges

  REF = %r{\A(?:(?<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@)?(?<sha>\h{7,40})\z}
  MAX_REFS = CommitStatus::MAX_SHAS
  HEAD_TTL = 2.minutes
  BRANCH_TTL = 1.hour

  # What the browser needs to decide which references to ask about.
  def self.config_for(account, user)
    new(account:, user:).config
  end

  def initialize(account:, user:)
    @account = account
    @user = user
  end

  def config
    { house_repo: (house_repo if house?), repos: account_repositories.map(&:full_name) }
  end

  def lookup(refs)
    parsed = Array(refs).filter_map { |ref| parse(ref) }.uniq { |ref, _, _| ref }.first(MAX_REFS)
    {
      statuses: statuses(parsed),
      revision: sources.map { |source| [ source[:repo], source[:revision] ].join("=") }.join(",")
    }
  end

  private

  def statuses(parsed)
    bare, named = parsed.partition { |_, repo, _| repo.nil? }
    answers = {}

    named.group_by { |_, repo, _| repo }.each do |repo, refs|
      source = sources.find { |s| s[:repo].casecmp?(repo) }
      shas = refs.map(&:last)
      found = source ? source[:status].lookup(shas) : {}
      refs.each { |ref, _, sha| answers[ref] = found[sha] }
    end

    if bare.any?
      shas = bare.map(&:last)
      probes = sources.map { |source| source[:status].probe(shas) }
      bare.each { |ref, _, sha| answers[ref] = only_answer(probes.map { |probe| probe[sha] }) }
    end

    answers
  end

  # The status from the one source that has the commit, when every other
  # source is sure it doesn't.
  def only_answer(results)
    results = results.compact
    return nil if results.empty?

    found = results.select { |presence, _| presence == :found }
    return nil unless found.one?
    return nil unless (results - found).all? { |presence, _| presence == :missing }

    found.first.last
  end

  def parse(ref)
    match = REF.match(ref.to_s.strip)
    return nil unless match

    sha = match[:sha].downcase
    repo = match[:repo]&.downcase
    [ repo ? "#{repo}@#{sha}" : sha, repo, sha ]
  end

  def sources
    @sources ||= begin
      list = []
      list << house_source if house?
      account_repositories.each do |repository|
        next if list.any? { |s| s[:repo].casecmp?(repository.full_name) }

        list << account_source(repository)
      end
      confirm = list.size > 1
      list.each { |source| source[:status] = source.delete(:build).call(confirm) }
    end
  end

  def house?
    @user&.is_site_admin? || false
  end

  def house_repo
    DeployInfo.repo
  end

  def house_source
    summary = DeployInfo.summary
    {
      repo: summary[:repo].to_s,
      revision: CommitStatus.revision(summary),
      # The deploy token keeps house lookups off the host's anonymous quota.
      build: ->(confirm) {
        token = HouseDeploy.token
        CommitStatus.new(summary, fetcher: ->(path) { CommitStatus.fetcher.call(path, token:) }, confirm_full: confirm)
      }
    }
  end

  def account_repositories
    return [] unless @account

    @account_repositories ||= @account.watched_repositories.live.where(commit_badges: true)
      .includes(:service_connection).order(:full_name)
      .select { |repository| repository.service_connection&.status == "connected" }
  end

  def account_source(repository)
    token = repository.service_connection.credential_payload_hash["token"].presence
    fetcher = ->(path) { CommitStatus.fetcher.call(path, token:) }
    scope = "account:#{@account.id}"
    head = default_branch_head(repository.full_name, fetcher, scope)
    summary = { repo: repository.full_name, master: head && { sha: head } }
    {
      repo: repository.full_name,
      revision: head.to_s,
      build: ->(confirm) { CommitStatus.new(summary, fetcher:, tracks_deploys: false, cache_scope: scope, confirm_full: confirm) }
    }
  end

  # The full sha at the tip of the repository's default branch, or nil.
  # Failures are not cached, so an outage stays "unknown".
  def default_branch_head(full_name, fetcher, scope)
    branch = Rails.cache.fetch("commit_badges:branch:#{scope}:#{full_name}", expires_in: BRANCH_TTL, skip_nil: true) do
      code, data = fetcher.call("/repos/#{full_name}")
      data["default_branch"].presence if code == 200 && data.is_a?(Hash)
    end
    return nil unless branch

    Rails.cache.fetch("commit_badges:head:#{scope}:#{full_name}", expires_in: HEAD_TTL, skip_nil: true) do
      code, data = fetcher.call("/repos/#{full_name}/commits/#{ERB::Util.url_encode(branch)}")
      sha = data["sha"].to_s.downcase if code == 200 && data.is_a?(Hash)
      sha if sha.to_s.match?(CommitStatus::FULL)
    end
  rescue StandardError => e
    Rails.logger.warn("[CommitBadges] head of #{full_name}: #{e.class}: #{e.message}")
    nil
  end

end
