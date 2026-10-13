class PagesController < ApplicationController

  allow_unauthenticated_access

  HOME_CHANGELOG_SIZE = 10

  def home
    render inertia: "home", props: { changelog: Changelog.entries.first(HOME_CHANGELOG_SIZE) }
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

  # Public, unlinked for now. Plans come from the catalogue, never from copy, and the
  # page must stay true with no Stripe keys: an unpriced plan offers no checkout.
  # Container sizes stay server-side until they are calibrated and delivered.
  def pricing
    render inertia: "pricing", props: {
      tiers: Billing::Tier.all.map { |tier| pricing_tier_json(tier) },
      billing_open: Billing.configured?,
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
      monthly_usd: tier.monthly_usd,
      allowance_usd: tier.allowance_usd,
      purchasable: tier.purchasable?
    }
  end

end
