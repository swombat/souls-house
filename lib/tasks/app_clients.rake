# First-party native-app OAuth clients (issue #94). Idempotent. Callbacks are
# claimed HTTPS links on the app's own host; no custom URL schemes.
namespace :app_clients do
  desc "Create or update the first-party native-app OAuth clients"
  task ensure: :environment do
    # This installation's own host, never a baked-in default: provisioning
    # another installation's callback would silently break its sign-in.
    host = ENV["APP_CLIENT_CALLBACK_HOST"].presence || ENV["SOULSHOUSE_DOMAIN"].presence ||
      abort("Set APP_CLIENT_CALLBACK_HOST (or SOULSHOUSE_DOMAIN) to this installation's host")
    {
      "souls-house-android" => "Souls House for Android",
      "souls-house-ios" => "Souls House for iOS"
    }.each do |uid, name|
      app = Doorkeeper::Application.find_or_initialize_by(uid: uid)
      app.update!(name: name, redirect_uri: "https://#{host}/app/oauth/callback", scopes: "chat", confidential: false)
      puts "#{uid}: #{app.redirect_uri}"
    end
  end
end
