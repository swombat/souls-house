require "test_helper"

class AppVersionTest < ActionDispatch::IntegrationTest

  test "health responses expose the configured application version and environment" do
    get "/up"

    assert_response :success
    assert_equal Rails.root.join("VERSION").read.strip, Rails.application.version.to_s
    assert_equal Rails.application.version.full, response.headers["X-App-Version"]
    assert_equal ENV.fetch("RAILS_APP_ENV", Rails.env), response.headers["X-App-Environment"]
  end

end
