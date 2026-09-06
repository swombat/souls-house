require "test_helper"

class Mnemodyne::ReembedVaultJobTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper

  setup do
    agent = agents(:research_assistant)
    agent.update_columns(runtime: "external")
    @vault = agent.create_memory_vault!
    @node = @vault.nodes.create!(node_type: "memory", content: "Synthetic restored handle")
    clear_enqueued_jobs
  end

  test "resuming a restored vault schedules its index after commit" do
    Mnemodyne::Embeddings.stub(:configured?, true) do
      @vault.update!(suspended_at: Time.current)
      assert_enqueued_with(job: Mnemodyne::ReembedVaultJob, args: [ @vault.id ]) do
        @vault.update!(suspended_at: nil)
      end
      assert_enqueued_with(job: Mnemodyne::EmbedNodeJob, args: [ @vault.id, @node.id ]) do
        Mnemodyne::ReembedVaultJob.perform_now(@vault.id)
      end
    end
  end

  test "suspension erasure and missing configuration do not enqueue embeddings" do
    Mnemodyne::Embeddings.stub(:configured?, false) do
      assert_no_enqueued_jobs { Mnemodyne::ReembedVaultJob.perform_now(@vault.id) }
    end
    Mnemodyne::Embeddings.stub(:configured?, true) do
      @vault.update!(suspended_at: Time.current)
      assert_no_enqueued_jobs { Mnemodyne::ReembedVaultJob.perform_now(@vault.id) }
      @vault.update_columns(suspended_at: nil, erasure_requested_at: Time.current)
      assert_no_enqueued_jobs { Mnemodyne::ReembedVaultJob.perform_now(@vault.id) }
    end
  end

end
