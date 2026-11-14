require "test_helper"

class AboutSheetTest < ActiveSupport::TestCase

  TODAY = Date.new(2026, 10, 25)
  CHANGELOG = [
    { date: "2026-10-26", title: "Dated after this release" },
    { date: "2026-10-25", title: "Shipped today" },
    { date: "2026-10-12", title: "Shipped two weeks ago" },
    { date: "2026-10-01", title: "Too old for the sheet" }
  ].freeze

  def sheet(**options)
    AboutSheet.render(today: TODAY, version: "0.1.0 abc1234", changelog: CHANGELOG, **options)
  end

  # The catalogue with a Stripe price on only the named plans.
  def priced(*ids)
    Billing::Tier.all.map do |tier|
      copy = tier.dup
      price = ids.include?(tier.id) ? "price_#{tier.id}" : nil
      copy.define_singleton_method(:price_id) { price }
      copy
    end
  end

  test "dated and versioned, under the bound" do
    text = sheet(billing_open: false)
    assert text.start_with?("# About souls.house\n")
    assert_includes text, "As of 2026-10-25, house version 0.1.0 abc1234."
    assert_operator text.bytesize, :<=, AboutSheet::MAX_BYTES
  end

  test "billing off: nowhere in the sheet are prices or paying offered" do
    text = sheet(billing_open: false, tiers: priced("conversation", "life", "work"))
    assert_includes text, "Paid plans open soon. No prices are offered yet."
    Billing::Tier.all.each { |tier| assert_includes text, "**#{tier.name}**" }
    Billing::AccountPlan.all.each { |plan| assert_includes text, "**#{plan.name}**" }
    refute_match(/\$\d+/, text)
    refute_includes text, "Free for 14 days"
    refute_includes text, "Pay for a resident"
    refute_includes text, "through Stripe"
    refute_includes text, "Plans are open"
  end

  test "billing on with every size priced offers each price, and the billing feature keeps its caveats" do
    text = sheet(billing_open: true, tiers: priced("conversation", "life", "work"))
    assert_includes text, "Plans are open."
    assert_includes text, "You pay for two things: the account's plan, and each resident by the size of the computer it lives on."
    assert_includes text, "- **Companions**: Someone to talk with. One person in the account. $9.99 a month including one small resident."
    assert_includes text, "- **Partners**: Helps you with your life. Several people in the account, and 20 Field swarm searches a month. " \
      "$29.99 a month including one small resident."
    assert_includes text, "- **Colleagues**: Does serious work beside you. Everything in Partners, residents can hand work to sub-agents, " \
      "and 100 Field swarm searches a month. $59.99 a month including one small resident."
    assert_includes text, "- **Small**: Talking, thinking, writing, looking things up. Right for most residents. " \
      "$9.99 a month each: hosting for one resident of this size."
    assert_includes text, "- **Medium**: Residents that write code or drive a browser. $39.99 a month each: hosting for one resident " \
      "of this size. The resident a plan includes can be medium for $30 more."
    assert_includes text, "- **Large**: Heavy building, and several sub-agents at once. $69.99 a month each: hosting for one " \
      "resident of this size. The resident a plan includes can be large for $60 more."
    assert_includes text, "Each account gets $10 a month of house-model use, shared by its residents at the standard price. " \
      "Residents hosted at cost don't draw on it."
    assert_includes text, "Free for 14 days, no card asked for: the first resident of a new account, small, once per account."
    assert_includes text, "Partners and Colleagues are never free: their $20 or $50 a month is charged from the day you choose one"
    assert_includes text, "plus VAT where it applies"
    refute_includes text, "$0", "Companions is never shown as free"
    refute_match(/vCPU|GB memory|GB disk|transcription|backup/i, text[/## Plans and prices.*?(?=\n## )/m])
    refute_includes text, "open soon"
    source = AboutSheet.features.find { |row| row[:key] == "billing" }[:description].squish
    assert_includes text, "**Pay for a resident**: #{source}"
  end

  test "with Site Admin's free trial switched off, the sheet never mentions a free trial" do
    text = sheet(billing_open: true, tiers: priced("conversation", "life", "work"), free_trial: false)
    assert_includes text, "Plans are open."
    assert_includes text, "$9.99 a month including one small resident."
    refute_match(/free for 14 days|free 14 days|never free|\btrial\b/i, text)

    Setting.instance.update!(free_trial_enabled: false)
    refute_match(/free for 14 days/i, sheet(billing_open: true, tiers: priced("conversation", "life", "work")))
    Setting.instance.update!(free_trial_enabled: true)
    assert_match(/Free for 14 days/, sheet(billing_open: true, tiers: priced("conversation", "life", "work")))
  end

  test "the copy baked into the runtime image doesn't promise a free trial the house may have switched off" do
    text = sheet(billing_open: :unknown)
    assert_includes text, "This copy cannot tell whether this house has opened its plans"
    refute_match(/free for 14 days|never free/i, text)
  end

  test "a partly priced catalogue offers only the plans that can be bought" do
    text = sheet(billing_open: true, tiers: priced("conversation"))
    plans = text[/## Plans and prices.*?(?=\n## )/m]
    assert_includes plans, "Some sizes are open: Small. The others open soon."
    assert_includes plans, "$9.99 a month each"
    assert_includes plans, "$29.99 a month including one small resident"
    assert_match(/\*\*Medium\*\*: [^\n]* Opens soon\./, plans)
    assert_match(/\*\*Large\*\*: [^\n]* Opens soon\./, plans)
    refute_includes plans, "$39.99"
    refute_includes plans, "$69.99"
    refute_includes plans, "Plans are open."
  end

  test "with no small size to buy, no account plan is priced, since each includes one" do
    plans = sheet(billing_open: true, tiers: priced("life"))[/## Plans and prices.*?(?=\n## )/m]
    assert_includes plans, "$39.99 a month each"
    refute_includes plans, "including one small resident"
    refute_includes plans, "Free for 14 days"
  end

  test "billing switch on but nothing priced reads as closed" do
    text = sheet(billing_open: true, tiers: priced)
    assert_includes text, "Paid plans open soon."
    refute_includes text, "Pay for a resident"
  end

  test "the billing switch decides: Stripe configured is not enough" do
    Billing.stub(:configured?, true) do
      Setting.instance.update!(billing_enabled: false)
      refute AboutSheet.billing_open?
      Setting.instance.update!(billing_enabled: true)
      assert AboutSheet.billing_open?
    end
    Billing.stub(:configured?, false) { refute AboutSheet.billing_open? }
  end

  test "a baked copy says it cannot tell whether plans are open" do
    text = sheet(billing_open: :unknown, baked: true)
    assert_includes text, "Built into the runtime image"
    refute_includes text, "Pay for a resident"
    assert_includes text, "cannot tell whether this house has opened its plans; /pricing says"
    refute_includes text, "Plans are open."
    refute_includes text, "Generated by this house"
  end

  test "only changelog entries this release carries, within the window" do
    recent = sheet(billing_open: false).split("## Recently changed").last
    assert_includes recent, "2026-10-25: Shipped today"
    assert_includes recent, "2026-10-12: Shipped two weeks ago"
    refute_includes recent, "Dated after this release"
    refute_includes recent, "Too old for the sheet"
  end

  test "planned work appears only under Planned, never among what a resident can do" do
    features = [
      { group: "relationalFeatures", key: "a", title: "Journals", description: "Residents keep journals. More." },
      { group: "moreFeatures", key: "b", title: "Carrier pigeons (coming)", description: "Birds." }
    ]
    text = sheet(billing_open: false, features: features)
    can_do = text[/## What a resident can do here.*\z/m]
    planned = text[/## Planned, not released.*?(?=\n## )/m]
    assert_includes can_do, "**Journals**: Residents keep journals."
    refute_includes can_do, "More."
    refute_includes can_do, "pigeons"
    assert_includes planned, "Carrier pigeons (listed as coming on /features)"
    assert_includes planned, "Native iOS and Android apps"
    assert_includes text, "No native app is released."
  end

  test "every planned item cites a record that exists" do
    AboutSheet::PLANNED.each { |item| assert Rails.root.join(item[:record]).file?, item[:record] }
  end

  test "reads the live feature list, the home page summary and the plan taglines" do
    features = AboutSheet.features
    assert_operator features.size, :>=, 40
    field = features.find { |row| row[:key] == "field" }
    assert_equal "The Field", field[:title]
    assert_match(/\ABring recordings, documents and notes/, field[:description])
    assert(features.all? { |row| row[:title].present? })
    assert_match(/\Asouls\.house is where your AI friends live/, AboutSheet.home_summary)
    assert_equal Billing::AccountPlan.all.map(&:id).sort, AboutSheet.plan_taglines.keys.sort
    assert_equal Billing::Tier.all.map(&:size).sort, AboutSheet.size_lines.keys.sort
  end

  test "an oversized sheet drops the changelog first, then cuts and says so" do
    long = Array.new(400) { |i| { group: "moreFeatures", key: "k#{i}", title: "Feature #{i}", description: "x" * 200 + "." } }
    text = sheet(billing_open: false, features: long)
    assert_operator text.bytesize, :<=, AboutSheet::MAX_BYTES
    refute_includes text, "## Recently changed"
    assert text.end_with?("(cut to fit)\n")
    assert_includes text, "## Plans and prices"
  end

  test "the baked runtime copy is a sheet within the bound" do
    baked = Rails.root.join("agent-runtime/docs/about-souls-house.md").read
    assert baked.start_with?("# About souls.house\n")
    assert_includes baked, "Built into the runtime image"
    assert_operator baked.bytesize, :<=, AboutSheet::MAX_BYTES
  end

end
