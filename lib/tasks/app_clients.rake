# First-party native-app OAuth clients (issue #94). Idempotent. Callbacks are
# claimed HTTPS links on the app's own host; no custom URL schemes.
namespace :app_clients do
  desc "Create or update the first-party native-app OAuth clients"
  task ensure: :environment do
    host = ENV.fetch("APP_CLIENT_CALLBACK_HOST", "souls.house")
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
