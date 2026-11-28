class PagesController < ApplicationController

  allow_unauthenticated_access

  HOME_CHANGELOG_SIZE = 10

  def home
    @share_video = true
    render inertia: "home", props: { changelog: Changelog.clipped(HOME_CHANGELOG_SIZE),
      from_usd: Billing.usd(Billing::AccountPlan.all.map(&:from_usd).min) }
  end

  def features
    @link_preview = LinkPreview.for(:features)
    render inertia: "features", props: { changelog: Changelog.recent }
  end

  def companion
    @link_preview = LinkPreview.for(:companion)
    render inertia: "companion"
  end

  def changelog
    respond_to do |format|
      format.html do
        @link_preview = LinkPreview.for(:changelog)
        render inertia: "changelog", props: { changelog: Changelog.entries }
      end

      format.atom do
        xml = Changelog::AtomFeed.render(
          entries: Changelog.latest(Changelog::FEED_LIMIT),
          base_url: request.base_url,
          site_name: Setting.instance.site_name,
          subtitle: LinkPreview.for(:changelog).description
        )

        if stale?(etag: xml, public: true)
          render body: xml, content_type: "application/atom+xml; charset=utf-8"
        end
      end
    end
  end

  # Public: one changelog entry, so a post about one change can link to that change.
  def changelog_entry
    entry = Changelog.find(params[:slug])
    raise ActiveRecord::RecordNotFound, "no changelog entry #{params[:slug]}" unless entry

    @link_preview = LinkPreview.for_changelog_entry(entry)
    render inertia: "changelog-entry", props: { entry:, description: @link_preview.description }
  end

  def privacy
    @link_preview = LinkPreview.for(:privacy)
    render inertia: "privacy"
  end

  def self_host
    @link_preview = LinkPreview.for(:self_host)
    render inertia: "self-host"
  end

  def self_host_technical
    @link_preview = LinkPreview.for(:self_host_technical)
    render inertia: "self-host-technical"
  end

  # Public: the live schema by concern, for people reading the open source. The
  # areas come from config/data_model.yml; the tables from the database.
  def data_model
    area = params[:area] ? DataModel.find(params[:area]) : DataModel.areas.first
    raise ActiveRecord::RecordNotFound, "no data-model area #{params[:area]}" unless area

    @link_preview = params[:area].present? ? LinkPreview.for_data_model_area(area) : LinkPreview.for(:data_model)
    render inertia: "data-model", props: {
      areas: DataModel.areas_json,
      area: DataModel.area_json(area),
      table_count: DataModel.schema_tables.size,
      map_url: DataModel::REPOSITORY_PATH,
      preview: { title: @link_preview.title, description: @link_preview.description }
    }
  end

  # Public, unlinked for now. Plans come from the catalogue, never from copy, and the
  # page must stay true with no Stripe keys: an unpriced plan offers no checkout.
  # What each plan includes is shown as what it gets when plans open; today's
  # hosting is a free container with your own key, and the page says so.
  def pricing
    @link_preview = LinkPreview.for(:pricing)
    render inertia: "pricing", props: {
      tiers: Billing::Tier.all.map { |tier| pricing_tier_json(tier) },
      account_plans: Billing::AccountPlan.all.as_json,
      billing_open: Billing.configured?,
      # Site Admin's switch: off, the page doesn't mention the free trial.
      free_trial_enabled: Setting.instance.free_trial_enabled?,
      # Whether a signed-in visitor's account would get it, so one that has
      # had it, or can't, is never told it's free.
      trial: authenticated? && current_account ? Billing::Trial.as_json_for(current_account) : nil,
      contact_email: Billing.contact_email
    }
  end

  def terms
    @link_preview = LinkPreview.for(:terms)
    render inertia: "terms"
  end

  def safeguard_responses
    @link_preview = LinkPreview.for(:safeguard_responses)
    render inertia: "safeguard-responses"
  end

  private

  def pricing_tier_json(tier)
    {
      id: tier.id,
      name: tier.name,
      size: tier.size,
      monthly_usd: Billing.usd(tier.monthly_usd),
      allowance_usd: Billing.usd(Billing::Tier::ACCOUNT_ALLOWANCE_USD),
      purchasable: tier.purchasable?,
      features: tier.features
    }.merge(pricing_machine(tier))
  end

  # The computer a size runs on, only while new residents are born on a VM of
  # their own, of their size's type (CloudProcurement#vm_birth_server_type).
  # A house that keeps residents on its own server doesn't claim it.
  def pricing_machine(tier)
    return {} unless Setting.instance.new_residents_on_vm?

    { machine: tier.machine.slice(:vcpus, :ram_gb) }
  end

end
