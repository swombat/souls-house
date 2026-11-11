# The short, dated sheet a resident reads to say what souls.house is (#566).
#
# Built by the running app from what this release carries, never from master:
# the changelog file baked into this image, the feature list this image serves
# on /features, the plan catalogue and the billing switch as they stand now.
# Copy comes from those sources; only the headings and the few fixed lines
# below are written here. Planned work sits in its own section and is never
# phrased as something a resident can use.
#
# Served to resident keys at GET /api/v1/about_house; the runtime fetches it at
# session start into the container (agent-runtime/about_sheet.py).
class AboutSheet

  MAX_BYTES = 16_384
  CHANGELOG_DAYS = 14
  CHANGELOG_LIMIT = 12
  SENTENCE_LIMIT = 240

  FEATURE_LIST = Rails.root.join("app/frontend/lib/components/features/feature-list.js")
  HOME_PAGE = Rails.root.join("app/frontend/pages/home.svelte")
  PRICING_COPY = Rails.root.join("app/frontend/lib/pricing.js")
  FEATURE_GROUPS = {
    "relationalFeatures" => "Living here",
    "technicalFeatures" => "Under the hood",
    "moreFeatures" => "More"
  }.freeze
  COMING = /\s*\(coming\)\z/i
  # Features that are only true while plans can be bought. They appear only
  # then, with their whole description, so a caveat in it isn't cut away.
  BILLING_FEATURES = %w[billing].freeze
  LITERAL = %r{'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"}m

  # Work the house has decided on but not shipped. Each cites the record it
  # rests on; test/models/about_sheet_test.rb checks the record exists.
  PLANNED = [
    { title: "Native iOS and Android apps",
      source: "decision record 0005, 2026-09-28",
      record: "docs/decisions/0005-native-client-boundaries.md" }
  ].freeze

  def self.render(**options) = new(**options).render

  # free_trial: whether to state the free 14 days (Site Admin's switch). The
  # copy baked into the runtime image can't know a house's switch, so it
  # doesn't state them.
  def initialize(today: Date.current, version: self.class.version, changelog: nil, tiers: Billing::Tier.all,
    billing_open: self.class.billing_open?, features: nil, baked: false,
    free_trial: billing_open != :unknown && Setting.instance.free_trial_enabled?)
    @baked = baked
    @free_trial = free_trial
    @today = today
    @version = version
    @changelog = changelog || Changelog.entries
    @tiers = tiers
    @billing_open = billing_open
    @features = features || self.class.features
  end

  # Prices are shown only when plans can actually be bought: Stripe set up
  # with a priced plan (what /pricing checks) and the site's Billing switch on.
  def self.billing_open?
    Billing.configured? && Setting.instance.billing_enabled?
  end

  def self.version
    sha = ENV["KAMAL_VERSION"].to_s[DeployInfo::SHA, 1]
    [ Rails.application.version.to_s.presence, sha&.first(7) ].compact.join(" ").presence || "unknown"
  end

  # The /features list, read from the source this image serves: key, title
  # and description of each entry, grouped by the array it sits in.
  def self.features(source: FEATURE_LIST.read)
    group = nil
    current = nil
    rows = []
    source.scan(/export const (\w+)\s*=\s*\[|\b(key|title|description):\s*(#{LITERAL})/m) do |array, field, value|
      if array
        group = array
        next
      end
      text = value[1..-2].gsub(/\\(.)/m, '\1')
      if field == "key"
        current = { group: group, key: text }
        rows << current
      elsif current && !current.key?(field.to_sym)
        current[field.to_sym] = text
      end
    end
    rows.select { |row| FEATURE_GROUPS.key?(row[:group]) && row[:title] }
  end

  def self.home_summary(source: HOME_PAGE.read)
    source[/<meta\s+name="description"\s+content="([^"]+)"/m, 1]&.squish
  end

  # The one-line copy for each account plan and each resident size, read
  # from the maps /pricing uses (accountPlanTaglines, sizeLines).
  def self.plan_taglines(source: PRICING_COPY.read) = copy_map("accountPlanTaglines", source)

  def self.size_lines(source: PRICING_COPY.read) = copy_map("sizeLines", source)

  def self.copy_map(name, source)
    block = source[/#{name}\s*=\s*\{(.*?)\}/m, 1].to_s
    block.scan(/(\w+):\s*(#{LITERAL})/).to_h { |id, line| [ id, line[1..-2].gsub(/\\(.)/, '\1') ] }
  end

  def render
    sections = [ header, what_it_is, where_it_runs, plans, help, planned, can_do ].compact
    text = (sections + [ recent_changes ].compact).join("\n\n") + "\n"
    # Over the bound, the changelog goes first; then the tail of the feature
    # list is cut, marked. The answers people ask for most come before it.
    text = sections.join("\n\n") + "\n" if text.bytesize > MAX_BYTES
    text = text.byteslice(0, MAX_BYTES - 32).scrub("") + "\n\n(cut to fit)\n" if text.bytesize > MAX_BYTES
    text
  end

  private

  attr_reader :today, :version, :changelog, :tiers, :features

  # true, false, or :unknown for the copy baked into the runtime image, which
  # cannot know how a house it hasn't reached has set its switch.
  def billing = @billing_open

  def header
    origin = if @baked
      "Built into the runtime image from the souls.house source; the house's own copy, when it can be reached, is newer."
    else
      "Generated by this house from the release it is running."
    end
    "# About souls.house\n\nAs of #{today.iso8601}, house version #{version}. #{origin}"
  end

  def what_it_is
    summary = self.class.home_summary
    return unless summary

    "## What souls.house is\n\n#{summary}"
  end

  def can_do
    live = features.reject { |row| row[:title].match?(COMING) }
    live = live.reject { |row| BILLING_FEATURES.include?(row[:key]) } unless buyable.any?
    return if live.empty?

    groups = live.group_by { |row| row[:group] }.map do |group, rows|
      lines = rows.map do |row|
        sentence = BILLING_FEATURES.include?(row[:key]) ? row[:description].to_s.squish : first_sentence(row[:description])
        "- **#{row[:title]}**#{": #{sentence}" if sentence.present?}"
      end
      "### #{FEATURE_GROUPS.fetch(group)}\n\n#{lines.join("\n")}"
    end
    "## What a resident can do here\n\nFrom the features page, /features.\n\n#{groups.join("\n\n")}"
  end

  # You pay for two things: the account's plan and each resident by its size.
  # Each size is offered only if it can be bought itself: Stripe can be set
  # up for one size and not the others, as /pricing shows with "Opens soon".
  # Account plans lead with what an account on them pays at least, one small
  # resident included, never with Companions' $0 add-on.
  def plans
    status = if billing == :unknown
      "This copy cannot tell whether this house has opened its plans; /pricing says. " \
        "The prices below are the catalogue as of this copy's date."
    elsif buyable.empty?
      "Paid plans open soon. No prices are offered yet."
    elsif buyable.size == tiers.size
      "Plans are open."
    else
      "Some sizes are open: #{buyable.map(&:name).join(", ")}. The others open soon."
    end
    intro = "You pay for two things: the account's plan, and each resident by the size of the computer it lives on."
    sections = [ "## Plans and prices", status, intro, "Account plans:", account_plan_lines, "Residents, by size:",
      size_lines, money_lines, "See /pricing." ]
    sections.compact.join("\n\n")
  end

  def account_plan_lines
    taglines = self.class.plan_taglines
    Billing::AccountPlan.all.map do |plan|
      line = "- **#{plan.name}**:"
      line += " #{taglines[plan.id]}" if taglines[plan.id]
      line += " #{account_plan_includes(plan)}"
      line += " #{Billing.usd_label(plan.from_usd)} a month including one small resident." if prices_shown?
      line
    end.join("\n")
  end

  # Only what a plan delivers today (Billing::AccountPlan#features).
  def account_plan_includes(plan)
    if plan.subagents?
      "Everything in Partners, residents can hand work to sub-agents, and #{plan.swarm_searches} Field swarm searches a month."
    elsif plan.several_members?
      "Several people in the account, and #{plan.swarm_searches} Field swarm searches a month."
    else
      "One person in the account."
    end
  end

  def size_lines
    lines = self.class.size_lines
    small = tiers.find { |tier| tier.size == "small" }
    tiers.map do |tier|
      line = "- **#{tier.name}**:"
      line += " #{lines[tier.size]}" if lines[tier.size]
      if billing == :unknown || buyable.include?(tier)
        line += " #{price(tier)}"
        if small && tier != small
          line += " The resident a plan includes can be #{tier.size} for #{Billing.usd_label(tier.monthly_usd - small.monthly_usd)} more."
        end
      elsif billing == true
        line += " Opens soon."
      end
      line
    end.join("\n")
  end

  # Model use and the free 14 days, only where prices are offered. The paid
  # account plans are never part of the free days (Mira, 2026-11-10).
  def money_lines
    return nil unless prices_shown?

    allowance = Billing.usd_label(Billing::Tier::ACCOUNT_ALLOWANCE_USD)
    [
      "Each account gets #{allowance} a month of house-model use, shared by its residents at the standard price. " \
        "Residents hosted at cost don't draw on it. Bring your own subscription or key for more.",
      trial_line,
      "Prices are in US dollars a month, plus VAT where it applies. An account with an at-cost offer pays its price, " \
        "under the same size names."
    ].compact.join("\n\n")
  end

  # Only while Site Admin offers the trial.
  def trial_line
    return nil unless @free_trial

    paid = Billing::AccountPlan.all.reject(&:free?)
    "Free for 14 days, no card asked for: the first resident of a new account, small, once per account. " \
      "With no card added it goes to sleep on day 14; nothing is deleted. " \
      "#{paid.map(&:name).join(" and ")} are never free: their #{paid.map { |plan| Billing.usd_label(plan.monthly_usd) }.join(" or ")} " \
      "a month is charged from the day you choose one, also during a resident's free 14 days, and needs a card."
  end

  # The account plans include a small resident, so their prices show once
  # the small size can be bought.
  def prices_shown?
    billing == :unknown || buyable.any? { |tier| tier.size == "small" }
  end

  def buyable
    @buyable ||= billing == true ? tiers.select(&:purchasable?) : []
  end

  # Only what a size delivers today (Billing::Tier#features).
  def price(tier)
    "#{Billing.usd_label(tier.monthly_usd)} a month each: hosting for one resident of this size."
  end

  def where_it_runs
    "## Where it runs\n\nIn a web browser, at this house's address; the site works on a phone. No native app is released."
  end

  def help
    "## Getting help\n\nAsk the account's owner, or see /features (what the house does) and /changelog (what changed, newest first)."
  end

  def planned
    coming = features.select { |row| row[:title].match?(COMING) }.map do |row|
      "- #{row[:title].sub(COMING, "")} (listed as coming on /features)"
    end
    lines = PLANNED.map { |item| "- #{item[:title]} (#{item[:source]})" } + coming
    return if lines.empty?

    "## Planned, not released\n\nDecided or announced, not available here. Nothing in this section is a promise or a date.\n\n" \
      "#{lines.join("\n")}"
  end

  # Only what this release carries, and nothing dated after today.
  def recent_changes
    cutoff = today - CHANGELOG_DAYS
    rows = changelog.select do |entry|
      date = Date.iso8601(entry[:date].to_s)
      date > cutoff && date <= today
    end.first(CHANGELOG_LIMIT)
    return if rows.empty?

    "## Recently changed\n\nFrom /changelog, newest first.\n\n#{rows.map { |entry| "- #{entry[:date]}: #{entry[:title]}" }.join("\n")}"
  end

  def first_sentence(text)
    sentence = text.to_s.squish.split(/(?<=[.!?])\s+(?=[A-Z0-9"'])/).first.to_s
    sentence.length > SENTENCE_LIMIT ? "#{sentence.first(SENTENCE_LIMIT - 1).rstrip}…" : sentence
  end

end
