require "test_helper"
require "support/field_ocr_helpers"

# Two workers reserving at once must not both take the last of the house's
# daily allowance (FieldOcr.reserve! holds one lock over the ledger).
class FieldOcrConcurrencyTest < ActiveSupport::TestCase

  include FieldOcrHelpers

  self.use_transactional_tests = false

  setup do
    @setting_was = Setting.instance.attributes.slice("field_ocr_enabled", "field_ocr_enabled_at", "field_ocr_daily_usd_ceiling")
    @account = Account.create!(name: "OCR race #{SecureRandom.hex(4)}", account_type: "team")
    enable_field_ocr(ceiling: BigDecimal("0.004"))
    @file = field_pdf(@account, "mixed.pdf")
  end

  teardown do
    disable_field_ocr
    FieldOcrCall.where(account: @account).delete_all
    FieldFilePage.where(field_file: @file).delete_all
    @file.file.purge
    FieldFile.where(id: @file.id).delete_all
    @account.destroy!
    Setting.instance.update_columns(@setting_was)
  end

  test "only one of two simultaneous reservations fits the ceiling" do
    results = concurrently(2) do |i|
      FieldOcr.reserve!(FieldFile.find(@file.id), 3 + i).class.name
    rescue FieldOcr::LimitReached
      "LimitReached"
    end

    assert_equal [ "FieldOcrCall", "LimitReached" ], results.sort
    assert_equal 1, FieldOcrCall.where(account: @account).count
  end

  test "two workers on the same page: one call, the other sees it in flight" do
    Setting.instance.update!(field_ocr_daily_usd_ceiling: 1)
    results = concurrently(2) { FieldOcr.reserve!(FieldFile.find(@file.id), 3).then { it.is_a?(FieldOcrCall) ? "call" : it.to_s } }

    assert_equal [ "call", "in_flight" ], results.sort
  end

  private

  def concurrently(count)
    ready, start = Queue.new, Queue.new
    threads = count.times.map do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          yield i
        end
      end
    end
    count.times { ready.pop }
    count.times { start << true }
    threads.map(&:value)
  end

end
