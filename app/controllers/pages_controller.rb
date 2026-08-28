class PagesController < ApplicationController

  allow_unauthenticated_access

  def home
    render inertia: "home"
  end

  def privacy
    render inertia: "privacy"
  end

  def terms
    render inertia: "terms"
  end

  def safeguard_responses
    render inertia: "safeguard-responses"
  end

end
