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

  test "a batched provider embeds the vault in place, skips current nodes and resumes" do
    second = @vault.nodes.create!(node_type: "memory", content: "Synthetic second handle")
    calls = []
    embed = lambda do |texts, **options|
      calls << [ texts, options[:input_type] ]
      texts.map { |text| [ text.length.to_f, 1.0 ] }
    end
    Mnemodyne::Embeddings.stub(:configured?, true) do
      Mnemodyne::Embeddings.stub(:batched?, true) do
        Mnemodyne::Embeddings.stub(:profile, "voyage-4") do
          Mnemodyne::Embeddings.stub(:embed_many, embed) do
            assert_no_enqueued_jobs(only: Mnemodyne::EmbedNodeJob) { Mnemodyne::ReembedVaultJob.perform_now(@vault.id) }
            assert_equal [ [ [ @node.embedding_text, second.embedding_text ].sort, :document ] ], calls.map { |texts, type| [ texts.sort, type ] }
            [ @node, second ].each do |node|
              node.reload
              assert_equal "voyage-4", node.embedding_profile
              assert_equal [ node.embedding_text.length.to_f, 1.0 ], node.embedding
            end
            Mnemodyne::ReembedVaultJob.perform_now(@vault.id)
            assert_equal 1, calls.length, "current nodes are not sent again"
            second.update!(content: "Synthetic changed handle")
            clear_enqueued_jobs
            Mnemodyne::ReembedVaultJob.perform_now(@vault.id)
            assert_equal [ "Synthetic changed handle" ], calls.last.first
          end
        end
      end
    end
  end

  test "a batch result never lands on text that changed while it was in flight" do
    embed = lambda do |texts, **|
      @node.update!(content: "Edited meanwhile")
      texts.map { [ 1.0, 1.0 ] }
    end
    Mnemodyne::Embeddings.stub(:configured?, true) do
      Mnemodyne::Embeddings.stub(:batched?, true) do
        Mnemodyne::Embeddings.stub(:profile, "voyage-4") do
          Mnemodyne::Embeddings.stub(:embed_many, embed) do
            Mnemodyne::ReembedVaultJob.perform_now(@vault.id)
            assert_nil @node.reload.embedding
          end
        end
      end
    end
  end

  test "the provider being down leaves old vectors untouched and raises for a retry" do
    @node.update_columns(embedding: [ 0.5, 0.5 ], embedding_profile: "bge-old", embedding_digest: Digest::SHA256.hexdigest(@node.embedding_text))
    Mnemodyne::Embeddings.stub(:configured?, true) do
      Mnemodyne::Embeddings.stub(:batched?, true) do
        Mnemodyne::Embeddings.stub(:profile, "voyage-4") do
          Mnemodyne::Embeddings.stub(:embed_many, ->(*, **) { raise Mnemodyne::Embeddings::Unavailable }) do
            assert_enqueued_with(job: Mnemodyne::ReembedVaultJob) { Mnemodyne::ReembedVaultJob.perform_now(@vault.id) }
            assert_equal "bge-old", @node.reload.embedding_profile
          end
        end
      end
    end
  end

end
