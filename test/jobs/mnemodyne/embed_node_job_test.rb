require "test_helper"

class Mnemodyne::EmbedNodeJobTest < ActiveSupport::TestCase

  setup do
    agent = agents(:research_assistant)
    agent.update_columns(runtime: "external")
    @vault = agent.create_memory_vault!
    @node = @vault.nodes.create!(node_type: "memory", content: "Synthetic handle")
  end

  test "stores configured embeddings only for the scoped current handle" do
    Mnemodyne::Embeddings.stub(:configured?, true) do
      Mnemodyne::Embeddings.stub(:profile, "synthetic-v1") do
        Mnemodyne::Embeddings.stub(:embed, [ 1.0, 0.0 ]) do
          Mnemodyne::EmbedNodeJob.perform_now(@vault.id, @node.id)
          assert_equal [ 1.0, 0.0 ], @node.reload.embedding
          assert_equal "synthetic-v1", @node.embedding_profile
          @node.update!(content: "Changed")
          assert_nil @node.embedding
        end
      end
    end
  end

  test "provider result cannot overwrite changed text or a suspended vault" do
    Mnemodyne::Embeddings.stub(:configured?, true) do
      Mnemodyne::Embeddings.stub(:profile, "synthetic-v1") do
        Mnemodyne::Embeddings.stub(:embed, ->(_) { @node.update!(content: "Later"); [ 1.0 ] }) do
          Mnemodyne::EmbedNodeJob.perform_now(@vault.id, @node.id)
          assert_nil @node.reload.embedding
        end
        Mnemodyne::Embeddings.stub(:embed, ->(_) { @vault.update!(suspended_at: Time.current); [ 1.0 ] }) do
          Mnemodyne::EmbedNodeJob.perform_now(@vault.id, @node.id)
          assert_nil @node.reload.embedding
        end
      end
    end
  end

  test "foreign and removed nodes never reach the provider" do
    Mnemodyne::Embeddings.stub(:embed, ->(_) { flunk "Unexpected provider call" }) do
      Mnemodyne::EmbedNodeJob.perform_now(@vault.id, SecureRandom.uuid)
      Mnemodyne::EmbedNodeJob.perform_now(SecureRandom.uuid, @node.id)
      assert_nil @node.reload.embedding
      @vault.update!(suspended_at: Time.current)
      Mnemodyne::EmbedNodeJob.perform_now(@vault.id, @node.id)
    end
  end

end
