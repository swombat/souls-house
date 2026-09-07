class PagesController < ApplicationController

  allow_unauthenticated_access

  def home
    render inertia: "home"
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
