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

  def terms
    render inertia: "terms"
  end

  def safeguard_responses
    render inertia: "safeguard-responses"
  end

end
