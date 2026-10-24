require "test_helper"
require "webmock/minitest"

class FieldVoiceprints::VoiceEmbeddingsTest < ActiveSupport::TestCase

  TOKEN = "t" * 32
  PROFILE = "ecapa-voxceleb-0f99f2d0ebe8-speechbrain-1.1.2-torch-2.14.1-v1"
  KEYS = %w[VOICE_EMBEDDING_URL VOICE_EMBEDDING_TOKEN].freeze

  setup { @previous = KEYS.index_with { |key| ENV[key] } }
  teardown { @previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value } }

  def configure(url = "http://souls-house-voice-embeddings:8080", token = TOKEN)
    ENV["VOICE_EMBEDDING_URL"] = url
    ENV["VOICE_EMBEDDING_TOKEN"] = token
  end

  def vector
    Array.new(192) { |i| (i + 1) / 192.0 }
  end

  test "unconfigured, or with a short token, it is off and sends nothing" do
    KEYS.each { |key| ENV.delete(key) }
    assert_not FieldVoiceprints::VoiceEmbeddings.configured?
    assert_raises(FieldVoiceprints::VoiceEmbeddings::Unavailable) { FieldVoiceprints::VoiceEmbeddings.embed("RIFF") }
    configure("http://souls-house-voice-embeddings:8080", "short")
    assert_not FieldVoiceprints::VoiceEmbeddings.configured?
    assert_not_requested :any, /voice-embeddings/
  end

  test "audio never goes to a plaintext host off the private network" do
    configure("http://voice.example.invalid:8080")
    assert_raises(FieldVoiceprints::VoiceEmbeddings::Unavailable) { FieldVoiceprints::VoiceEmbeddings.embed("RIFF") }
    assert_not_requested :any, /voice\.example\.invalid/
  end

  test "embed sends the WAV with the bearer token and returns the vector and profile" do
    configure
    endpoint = stub_request(:post, "http://souls-house-voice-embeddings:8080/embed")
      .with(body: "RIFFsynthetic", headers: { "Authorization" => "Bearer #{TOKEN}", "Content-Type" => "audio/wav" })
      .to_return(body: { embedding: vector, profile: PROFILE }.to_json)
    result = FieldVoiceprints::VoiceEmbeddings.embed("RIFFsynthetic")
    assert_requested endpoint
    assert_equal vector, result.embedding
    assert_equal PROFILE, result.profile
  end

  test "malformed, wrong-sized or failed responses are Unavailable and say nothing about the service" do
    configure
    endpoint = stub_request(:post, "http://souls-house-voice-embeddings:8080/embed")
    bad = [
      "not-json", "[]", { embedding: vector }.to_json,
      { embedding: vector.first(191), profile: PROFILE }.to_json,
      { embedding: Array.new(192, 0), profile: PROFILE }.to_json,
      { embedding: vector, profile: "bge-small" }.to_json,
      "x" * 64_001
    ]
    bad.each do |body|
      endpoint.to_return(body: body)
      error = assert_raises(FieldVoiceprints::VoiceEmbeddings::Unavailable) { FieldVoiceprints::VoiceEmbeddings.embed("RIFF") }
      assert_not_includes error.message, "souls-house-voice-embeddings"
      assert_nil error.cause
    end
    endpoint.to_return(status: 400, body: { error: "Invalid audio" }.to_json)
    assert_raises(FieldVoiceprints::VoiceEmbeddings::Unavailable) { FieldVoiceprints::VoiceEmbeddings.embed("RIFF") }
    endpoint.to_timeout
    assert_raises(FieldVoiceprints::VoiceEmbeddings::Unavailable) { FieldVoiceprints::VoiceEmbeddings.embed("RIFF") }
  end

  test "oversized or empty audio is refused before any request" do
    configure
    [ "", "x" * (8 * 1024 * 1024 + 1), nil ].each do |wav|
      assert_raises(FieldVoiceprints::VoiceEmbeddings::Unavailable) { FieldVoiceprints::VoiceEmbeddings.embed(wav) }
    end
    assert_not_requested :post, "http://souls-house-voice-embeddings:8080/embed"
  end

  test "health reports ready only for a 192-dimension ECAPA profile" do
    configure
    endpoint = stub_request(:get, "http://souls-house-voice-embeddings:8080/health")
      .with(headers: { "Authorization" => "Bearer #{TOKEN}" })
      .to_return(body: { ready: true, profile: PROFILE, dimensions: 192 }.to_json)
    health = FieldVoiceprints::VoiceEmbeddings.health
    assert health.ready
    assert_equal PROFILE, health.profile
    [ { ready: false, profile: PROFILE, dimensions: 192 }, { ready: true, profile: PROFILE, dimensions: 384 } ].each do |body|
      endpoint.to_return(body: body.to_json)
      assert_raises(FieldVoiceprints::VoiceEmbeddings::Unavailable) { FieldVoiceprints::VoiceEmbeddings.health }
    end
  end

  test "the configured WeSpeaker contract accepts exactly its 256-dimensional recipe" do
    configure
    profile = FieldVoiceprints::Profiles::WESPEAKER
    Setting.instance.update!(voice_embedding_profile: profile)
    values = [ 1.0 ] + [ 0.0 ] * 255
    endpoint = stub_request(:post, "http://souls-house-voice-embeddings:8080/embed")
      .to_return(body: { embedding: values, profile: }.to_json)
    assert_equal values, FieldVoiceprints::VoiceEmbeddings.embed("RIFFsynthetic").embedding
    [
      { embedding: vector, profile: PROFILE },
      { embedding: vector, profile: },
      { embedding: values, profile: "#{profile}-different" },
      { embedding: Array.new(256, 0.0), profile: }
    ].each do |payload|
      endpoint.to_return(body: payload.to_json)
      assert_raises(FieldVoiceprints::VoiceEmbeddings::Unavailable) { FieldVoiceprints::VoiceEmbeddings.embed("RIFFsynthetic") }
    end
    health = stub_request(:get, "http://souls-house-voice-embeddings:8080/health")
      .to_return(body: { ready: true, dimensions: 256, profile: }.to_json)
    assert_equal profile, FieldVoiceprints::VoiceEmbeddings.health.profile
    health.to_return(body: { ready: true, dimensions: 192, profile: }.to_json)
    assert_raises(FieldVoiceprints::VoiceEmbeddings::Unavailable) { FieldVoiceprints::VoiceEmbeddings.health }
    assert_not FieldVoiceprints::Profiles.valid_vector?([ Float::NAN ] * 256, profile)
    assert_not FieldVoiceprints::Profiles.valid_vector?([ Float::INFINITY ] * 256, profile)
  end

end
