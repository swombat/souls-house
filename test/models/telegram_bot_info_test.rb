require "test_helper"
require "ostruct"

# getMe's can_read_all_group_messages is optional in the Bot API: with
# BotFather privacy mode on it may be absent rather than false (#646 review).
class TelegramBotInfoTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    fake_ok = OpenStruct.new(body: { "ok" => true, "result" => {} }.to_json)
    @agent = Net::HTTP.stub :post, fake_ok do
      @account.agents.create!(
        name: "Info Agent",
        telegram_bot_token: "4343:ABC",
        telegram_bot_username: "info_bot",
        runtime: "external",
        endpoint_url: "https://agent.example.com",
        trigger_bearer_token: "tr_valid"
      )
    end
  end

  test "an absent field on a successful getMe reads as privacy on" do
    refresh_with("ok" => true, "result" => { "id" => 4343, "is_bot" => true })
    assert_equal false, @agent.reload.telegram_reads_all_group_messages
  end

  test "a bot that could read everything and now omits the field is marked restricted" do
    @agent.update_column(:telegram_reads_all_group_messages, true)
    refresh_with("ok" => true, "result" => { "id" => 4343, "is_bot" => true })
    assert_equal false, @agent.reload.telegram_reads_all_group_messages
  end

  test "an explicit true is stored" do
    refresh_with("ok" => true, "result" => { "id" => 4343, "can_read_all_group_messages" => true })
    assert_equal true, @agent.reload.telegram_reads_all_group_messages
  end

  test "a failed getMe keeps the stored value" do
    @agent.update_column(:telegram_reads_all_group_messages, true)
    refresh_with("ok" => false, "description" => "Unauthorized")
    assert_equal true, @agent.reload.telegram_reads_all_group_messages

    @agent.update_column(:telegram_reads_all_group_messages, nil)
    refresh_with("ok" => false, "description" => "Unauthorized")
    assert_nil @agent.reload.telegram_reads_all_group_messages
  end

  private

  def refresh_with(response)
    @agent.define_singleton_method(:telegram_api_request) { |_method, _body| response }
    @agent.refresh_telegram_bot_info!
  end

end
