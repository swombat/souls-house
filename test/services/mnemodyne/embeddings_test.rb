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

end
