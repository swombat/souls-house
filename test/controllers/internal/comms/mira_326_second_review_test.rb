require "test_helper"
# Mira's regression from her second review of #326 at f6d3d556, unchanged.
require "support/telegram_comms_helpers"

class Mira326SecondReviewTest < ActionDispatch::IntegrationTest
  include TelegramCommsHelpers

  test "generation-less completion cannot replace identity after newer login finishes" do
    connection = telegram_connection(account: accounts(:personal_account), user: users(:user_1),
                                     generation: 4)
    connection.update!(external_subject_id: "current-account", external_identity: "Current")
    post_telegram_event connection, { type: "status.changed", status: "connected", seq: 1,
                                      identity: { user_id: "obsolete-account", display_name: "Obsolete" } }
    assert_equal "current-account", connection.reload.external_subject_id
    assert_equal "Current", connection.external_identity
  end
end
