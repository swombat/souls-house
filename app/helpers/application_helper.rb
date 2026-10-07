module ApplicationHelper

  # Kept in step with TINT_CHROMA in app/frontend/lib/theme.js (a test checks they match).
  TINT_CHROMA = 0.018

  # Attributes for <html> so the personal tint and the account's logo colour are right on
  # first paint, before Svelte mounts. The client keeps them current on Inertia navigation.
  def html_theme_attributes
    attributes = {}
    hue = Current.user&.theme_hue
    attributes[:style] = "--tint-h: #{hue.to_i}; --tint-c: #{TINT_CHROMA}" unless hue.nil?
    colour = current_account&.logo_colour if respond_to?(:current_account)
    attributes[:data] = { account_colour: colour } if colour.present?
    attributes
  end

end
