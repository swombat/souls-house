require "test_helper"
require "webmock/minitest"

class Mnemodyne::EmbeddingsTest < ActiveSupport::TestCase

  test "configured HTTP provider validates shape vectors and failure responses" do
    previous = ENV.to_h.slice("MNEMODYNE_EMBEDDING_URL", "MNEMODYNE_EMBEDDING_PROFILE")
    ENV["MNEMODYNE_EMBEDDING_URL"] = "http://synthetic-embeddings.invalid/embed"
    ENV["MNEMODYNE_EMBEDDING_PROFILE"] = "synthetic-v1"
    endpoint = stub_request(:post, ENV["MNEMODYNE_EMBEDDING_URL"])
      .with(body: { input: "Synthetic text", model: "synthetic-v1" }.to_json)
    endpoint.to_return(body: { data: [ { embedding: [ 1.0, 0.5 ] } ] }.to_json)
    assert_equal [ 1.0, 0.5 ], Mnemodyne::Embeddings.embed("Synthetic text")
    [ "{}", "not-json", { data: [ { embedding: [ 0, 0 ] } ] }.to_json, "x" * 200_001 ].each do |body|
      endpoint.to_return(body: body)
      assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::Embeddings.embed("Synthetic text") }
    end
    endpoint.to_return(status: 302, headers: { "Location" => "https://foreign.invalid" })
    assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::Embeddings.embed("Synthetic text") }
    endpoint.to_timeout
    assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::Embeddings.embed("Synthetic text") }
  ensure
    %w[MNEMODYNE_EMBEDDING_URL MNEMODYNE_EMBEDDING_PROFILE].each { |key| ENV[key] = previous[key] }
  end

end
