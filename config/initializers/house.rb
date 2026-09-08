# Be sure to restart your server when you modify this file.

# The public URL this house is reachable at (used for webhook callbacks and
# links generated outside a request, e.g. in jobs). Defaults to the value
# already configured under credentials.app.url so upstream behaviour is
# unchanged; a fork sets SOULSHOUSE_PUBLIC_URL instead of editing credentials.
Rails.application.config.x.public_url =
  ENV["SOULSHOUSE_PUBLIC_URL"].presence || Rails.application.credentials.dig(:app, :url)
