require "test_helper"
require "webmock/minitest"

class Mnemodyne::EmbeddingsTest < ActiveSupport::TestCase

  test "off box plaintext endpoint is rejected before any request" do
    previous = ENV.to_h.slice("MNEMODYNE_EMBEDDING_URL", "MNEMODYNE_EMBEDDING_PROFILE")
    ENV["MNEMODYNE_EMBEDDING_URL"] = "http://synthetic-embeddings.invalid/embed"
    ENV["MNEMODYNE_EMBEDDING_PROFILE"] = "synthetic-v1"
    assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::Embeddings.embed("Never sent") }
    assert_not_requested :post, ENV["MNEMODYNE_EMBEDDING_URL"]
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  test "configured HTTP provider validates shape vectors and failure responses" do
    previous = ENV.to_h.slice("MNEMODYNE_EMBEDDING_URL", "MNEMODYNE_EMBEDDING_PROFILE")
    ENV["MNEMODYNE_EMBEDDING_URL"] = "https://synthetic-embeddings.invalid/embed"
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

  def with_endpoint
    previous = ENV.to_h.slice("MNEMODYNE_EMBEDDING_URL", "MNEMODYNE_EMBEDDING_PROFILE")
    ENV["MNEMODYNE_EMBEDDING_URL"] = "https://synthetic-embeddings.invalid/embed"
    ENV["MNEMODYNE_EMBEDDING_PROFILE"] = "synthetic-v1"
    yield stub_request(:post, ENV["MNEMODYNE_EMBEDDING_URL"])
  ensure
    %w[MNEMODYNE_EMBEDDING_URL MNEMODYNE_EMBEDDING_PROFILE].each { |key| ENV[key] = previous[key] }
  end

  VECTOR = { data: [ { embedding: [ 1.0, 0.5 ] } ] }.to_json

  test "a busy slot is retried once and the second answer is used" do
    with_endpoint do |endpoint|
      endpoint.to_return({ status: 503, body: { error: "Busy" }.to_json }, { body: VECTOR })
      assert_equal [ 1.0, 0.5 ], Mnemodyne::Embeddings.embed("Synthetic text")
      assert_requested endpoint, times: 2
    end
  end

  test "a second busy answer is final: no third attempt" do
    with_endpoint do |endpoint|
      endpoint.to_return(status: 503, body: { error: "Busy" }.to_json)
      assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::Embeddings.embed("Synthetic text") }
      assert_requested endpoint, times: 2
    end
  end

  test "an oversized 503 body fails closed without a retry" do
    with_endpoint do |endpoint|
      endpoint.to_return({ status: 503, body: "x" * 200_001 }, { body: VECTOR })
      assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::Embeddings.embed("Synthetic text") }
      assert_requested endpoint, times: 1
    end
  end

  test "only 503 is retried" do
    [ 400, 401, 500 ].each do |status|
      with_endpoint do |endpoint|
        endpoint.to_return(status: status, body: "{}")
        assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::Embeddings.embed("Synthetic text") }
        assert_requested endpoint, times: 1
        WebMock::RequestRegistry.instance.reset!
      end
    end
  end

  test "a late 503 and a slow retry still end inside the one overall budget" do
    with_endpoint do |endpoint|
      endpoint.to_return(
        ->(_request) { sleep 1.5; { status: 503, body: { error: "Busy" }.to_json } },
        ->(_request) { sleep 1.0; { body: VECTOR } }
      )
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::Embeddings.embed("Synthetic text") }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, Mnemodyne::Embeddings::OVERALL_SECONDS + 0.2
      assert_requested endpoint, times: 2
    end
  end

  test "no retry when the budget left cannot hold one" do
    with_endpoint do |endpoint|
      endpoint.to_return(->(_request) { sleep 1.85; { status: 503, body: "{}" } }, { body: VECTOR })
      assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::Embeddings.embed("Synthetic text") }
      assert_requested endpoint, times: 1
    end
  end

  def with_voyage(key: "synthetic-voyage-key")
    previous = ENV["MNEMODYNE_EMBEDDING_PROFILE"]
    ENV["MNEMODYNE_EMBEDDING_PROFILE"] = "voyage-4"
    Mnemodyne::Embeddings.stub(:voyage_key, key) do
      yield stub_request(:post, Mnemodyne::Embeddings::VOYAGE_URL)
    end
  ensure
    ENV["MNEMODYNE_EMBEDDING_PROFILE"] = previous
  end

  test "a voyage profile calls Voyage with the house key and the input type" do
    with_voyage do |endpoint|
      endpoint.with(body: { input: [ "Synthetic query" ], model: "voyage-4", input_type: "query" }.to_json,
        headers: { "Authorization" => "Bearer synthetic-voyage-key" })
        .to_return(body: { data: [ { index: 0, embedding: [ 0.25, 0.5 ] } ] }.to_json)
      assert Mnemodyne::Embeddings.configured?
      assert Mnemodyne::Embeddings.batched?
      assert_equal [ 0.25, 0.5 ], Mnemodyne::Embeddings.embed("Synthetic query", input_type: :query)
      assert_requested endpoint, times: 1
    end
  end

  test "a voyage batch comes back in input order whatever order Voyage lists it" do
    with_voyage do |endpoint|
      endpoint.with(body: hash_including(input: [ "First", "Second" ], input_type: "document"))
        .to_return(body: { data: [ { index: 1, embedding: [ 0.0, 2.0 ] }, { index: 0, embedding: [ 1.0, 0.0 ] } ] }.to_json)
      assert_equal [ [ 1.0, 0.0 ], [ 0.0, 2.0 ] ], Mnemodyne::Embeddings.embed_many([ "First", "Second" ])
    end
  end

  test "voyage without a key is not configured and sends nothing" do
    with_voyage(key: nil) do |endpoint|
      assert_not Mnemodyne::Embeddings.configured?
      assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::Embeddings.embed("Never sent") }
      assert_not_requested endpoint
    end
  end

  test "voyage refusals and short or mixed answers are unavailable, never a fallback" do
    with_voyage do |endpoint|
      [ { status: 401, body: "{}" }, { status: 500, body: "{}" },
        { body: { data: [] }.to_json },
        { body: { data: [ { index: 0, embedding: [ 1.0 ] }, { index: 1, embedding: [ 1.0, 2.0 ] } ] }.to_json } ].each do |response|
        endpoint.to_return(response)
        assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::Embeddings.embed_many([ "A", "B" ]) }
      end
    end
  end

  test "a voyage rate limit is retried once inside the budget" do
    with_voyage do |endpoint|
      endpoint.to_return({ status: 429, body: "{}" }, { body: { data: [ { index: 0, embedding: [ 1.0 ] } ] }.to_json })
      assert_equal [ 1.0 ], Mnemodyne::Embeddings.embed("Synthetic text")
      assert_requested endpoint, times: 2
    end
  end

  test "the private accessory takes one text at a time" do
    with_endpoint do |endpoint|
      assert_raises(Mnemodyne::Embeddings::Unavailable) { Mnemodyne::Embeddings.embed_many([ "A", "B" ]) }
      assert_not_requested endpoint
    end
  end

  test "voyage indexes must be exactly 0...count or the whole answer is refused" do
    with_voyage do |endpoint|
      [ [ 0, 0 ], [ 0, 2 ], [ 1, nil ], [ -1, 0 ], [ "0", 1 ] ].each do |indexes|
        data = indexes.each_with_index.map { |index, i| { index: index, embedding: [ i + 1.0, 1.0 ] }.compact }
        endpoint.to_return(body: { data: data }.to_json)
        assert_raises(Mnemodyne::Embeddings::Unavailable, indexes.inspect) { Mnemodyne::Embeddings.embed_many([ "A", "B" ]) }
      end
    end
  end

  test "cosine matches the textbook formula and its edges" do
    random = Random.new(7)
    20.times do
      a = Array.new(1024) { random.rand(-1.0..1.0) }
      b = Array.new(1024) { random.rand(-1.0..1.0) }
      expected = a.zip(b).sum { |x, y| x * y } / Math.sqrt(a.sum { |x| x * x } * b.sum { |x| x * x })
      assert_in_delta expected, Mnemodyne::Embeddings.cosine(a, b), 1e-12
    end
    assert_in_delta 1.0, Mnemodyne::Embeddings.cosine([ 1.0, 2.0 ], [ 2.0, 4.0 ]), 1e-12
    assert_equal 0.0, Mnemodyne::Embeddings.cosine([ 0.0, 0.0 ], [ 1.0, 1.0 ])
    assert_equal 0.0, Mnemodyne::Embeddings.cosine([ 1.0 ], [ 1.0, 2.0 ])
    assert_equal 0.0, Mnemodyne::Embeddings.cosine(nil, [ 1.0 ])
    assert_equal 0.0, Mnemodyne::Embeddings.cosine([], [])
  end

end
