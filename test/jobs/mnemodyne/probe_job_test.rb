require "test_helper"

class Mnemodyne::ProbeJobTest < ActiveSupport::TestCase

  test "unconfigured probe reports and fails rather than going green" do
    reports = []
    Rails.error.stub(:report, ->(*args, **options) { reports << options }) do
      Mnemodyne::Embeddings.stub(:configured?, false) do
        assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::ProbeJob.perform_now }
      end
    end
    assert_equal false, reports.first[:handled]
    assert_equal "mnemodyne_embeddings", reports.first.dig(:context, :subsystem)
  end

end
