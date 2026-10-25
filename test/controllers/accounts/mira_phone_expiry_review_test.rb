require "test_helper"
require "support/telegram_comms_helpers"

class MiraPhoneExpiryReviewTest < ActiveSupport::TestCase

  include TelegramCommsHelpers

  test "a code response delivered after the attempt expired does not revive it" do
    connection = telegram_connection(account: accounts(:team), user: users(:admin),
      status: "pairing", generation: 4)
    connection.update!(connector_state: { "login" => { "error" => "expired" } })

    connection.record_login_code_step!(4, { "step" => "code", "delivery" => "app" })

    assert_equal "expired", connection.reload.login_state["error"]
  end

end
