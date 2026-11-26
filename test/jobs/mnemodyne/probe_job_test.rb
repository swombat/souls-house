require "test_helper"
require "webmock/minitest"

class Mnemodyne::ProbeJobTest < ActiveSupport::TestCase

  test "unconfigured probe reports and fails rather than going green" do
    reports = []
    Rails.error.stub(:report, ->(*args, **options) { reports << options }) do
      Mnemodyne::Embeddings.stub(:configured?, false) do
        error = assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::ProbeJob.perform_now }
        assert_equal :not_configured, error.reason
      end
    end
    assert_equal false, reports.first[:handled]
    assert_equal "mnemodyne_embeddings", reports.first.dig(:context, :subsystem)
    assert_equal :not_configured, reports.first.dig(:context, :reason)
  end

  test "the provider's reason reaches the raised error, the report and the log" do
    previous = ENV.to_h.slice("MNEMODYNE_EMBEDDING_URL", "MNEMODYNE_EMBEDDING_PROFILE")
    ENV["MNEMODYNE_EMBEDDING_URL"] = "https://synthetic-embeddings.invalid/embed"
    ENV["MNEMODYNE_EMBEDDING_PROFILE"] = "synthetic-v1"
    stub_request(:post, ENV["MNEMODYNE_EMBEDDING_URL"]).to_return(status: 429, body: "{}")
    reports = []
    log = StringIO.new
    logger = ActiveSupport::Logger.new(log)
    error = Rails.stub(:logger, logger) do
      Rails.error.stub(:report, ->(*args, **options) { reports << options }) do
        assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::ProbeJob.perform_now }
      end
    end
    assert_equal "Mnemodyne embeddings unavailable: rate_limited (429)", error.message
    assert_equal({ subsystem: "mnemodyne_embeddings", reason: :rate_limited, status: 429 }, reports.first[:context])
    assert_includes log.string, "Mnemodyne embedding readiness failed: Mnemodyne embeddings unavailable: rate_limited (429)"
    assert_not_includes log.string, "synthetic-embeddings.invalid"
  ensure
    %w[MNEMODYNE_EMBEDDING_URL MNEMODYNE_EMBEDDING_PROFILE].each { |key| ENV[key] = previous[key] }
  end


  test "the probe precheck does not carry a caller's active exception" do
    error = Rails.error.stub(:report, ->(*, **) { }) do
      Mnemodyne::Embeddings.stub(:configured?, false) do
        begin
          raise RuntimeError, "outer-private-detail"
        rescue RuntimeError
          assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::ProbeJob.perform_now }
        end
      end
    end
    assert_nil error.cause
    assert_not_includes error.full_message, "outer-private-detail"
  end

  test "a timed-out probe's failed row says where the call had got to" do
    previous = ENV.to_h.slice("MNEMODYNE_EMBEDDING_URL", "MNEMODYNE_EMBEDDING_PROFILE")
    ENV["MNEMODYNE_EMBEDDING_URL"] = "https://synthetic-embeddings.invalid/embed"
    ENV["MNEMODYNE_EMBEDDING_PROFILE"] = "synthetic-v1"
    stub_request(:post, ENV["MNEMODYNE_EMBEDDING_URL"]).to_raise(Net::ReadTimeout)
    reports = []
    error = Rails.error.stub(:report, ->(*args, **options) { reports << options }) do
      assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::ProbeJob.perform_now }
    end
    assert_match(/\Atimeout \(Net::ReadTimeout\) \[phase connected, attempt 1, connect \d+ ms, elapsed \d+ ms\]\z/,
      error.message.delete_prefix("Mnemodyne embeddings unavailable: "))
    context = reports.first[:context]
    assert_equal :connected, context[:phase]
    assert_equal 1, context[:attempts]
    assert_kind_of Integer, context[:elapsed_ms]
    assert_not_includes error.message, "synthetic-embeddings.invalid"
  ensure
    %w[MNEMODYNE_EMBEDDING_URL MNEMODYNE_EMBEDDING_PROFILE].each { |key| ENV[key] = previous[key] }
  end

end
