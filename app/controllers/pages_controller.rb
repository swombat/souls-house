class PagesController < ApplicationController

  allow_unauthenticated_access

  HOME_CHANGELOG_SIZE = 10

  def home
    @share_video = true
    render inertia: "home", props: { changelog: Changelog.clipped(HOME_CHANGELOG_SIZE),
      from_usd: Billing.usd(Billing::AccountPlan.all.map(&:from_usd).min) }
  end

  def features
    render inertia: "features", props: { changelog: Changelog.recent }
  end

  def changelog
    render inertia: "changelog", props: { changelog: Changelog.entries }
  end

  def privacy
    render inertia: "privacy"
  end

  def self_host
    render inertia: "self-host"
  end

  def self_host_technical
    render inertia: "self-host-technical"
  end

  # Public: the live schema by concern, for people reading the open source. The
  # areas come from config/data_model.yml; the tables from the database.
  def data_model
    area = params[:area] ? DataModel.find(params[:area]) : DataModel.areas.first
    raise ActiveRecord::RecordNotFound, "no data-model area #{params[:area]}" unless area

    render inertia: "data-model", props: {
      areas: DataModel.areas_json,
      area: DataModel.area_json(area),
      table_count: DataModel.schema_tables.size,
      map_url: DataModel::REPOSITORY_PATH
    }
  end

  # Public, unlinked for now. Plans come from the catalogue, never from copy, and the
  # page must stay true with no Stripe keys: an unpriced plan offers no checkout.
  # What each plan includes is shown as what it gets when plans open; today's
  # hosting is a free container with your own key, and the page says so.
  def pricing
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
    render inertia: "terms"
  end

  def safeguard_responses
    render inertia: "safeguard-responses"
  end

  private

  def pricing_tier_json(tier)
    {
      id: tier.id,
      name: tier.name,
      size: tier.size,
      monthly_usd: Billing.usd(tier.monthly_usd),
      allowance_usd: Billing.usd(tier.allowance_usd),
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
