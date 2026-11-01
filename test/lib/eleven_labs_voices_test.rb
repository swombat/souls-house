require "test_helper"
require "webmock/minitest"

class ElevenLabsVoicesTest < ActiveSupport::TestCase

  setup { WebMock.disable_net_connect! }
  teardown { WebMock.allow_net_connect! }

  def voices_payload
    {
      voices: [
        { voice_id: "premade-z", name: "Zara", category: "premade", description: "Warm and calm.",
          labels: { accent: "british", age: "young", gender: "female", use_case: "narration", extra: "dropped" },
          preview_url: "https://storage.example/z.mp3" },
        { voice_id: "cloned-1", name: "Daniel clone", category: "cloned", labels: {} },
        { voice_id: "designed-1", name: "Designed", category: "generated", labels: {} },
        { voice_id: "premade-a", name: "adam", category: "premade", labels: { description: "deep" } },
        { name: "No id", category: "premade" }
      ]
    }.to_json
  end

  test "only the standard (premade) voices are offered, sorted by name, with their labels" do
    stub = stub_request(:get, ElevenLabsVoices::API_URL).with(headers: { "xi-api-key" => "k" })
      .to_return(status: 200, body: voices_payload)

    voices = ElevenLabsVoices.stub(:api_key, "k") { ElevenLabsVoices.catalogue }

    assert_requested stub
    assert_equal %w[premade-a premade-z], voices.map(&:voice_id)
    zara = voices.last
    assert_equal "Warm and calm.", zara.description
    assert_equal({ "accent" => "british", "age" => "young", "gender" => "female", "use_case" => "narration" }, zara.labels)
    assert_equal "deep", voices.first.description, "a labels description stands in for a missing one"
    assert ElevenLabsVoices.stub(:api_key, "k") { ElevenLabsVoices.standard?("premade-z") }
    assert_not ElevenLabsVoices.stub(:api_key, "k") { ElevenLabsVoices.standard?("cloned-1") }
  end

  test "a failed or unreadable list is Unavailable, not an empty catalogue" do
    stub_request(:get, ElevenLabsVoices::API_URL).to_return(status: 500, body: "nope")
    assert_raises(ElevenLabsVoices::Unavailable) { ElevenLabsVoices.stub(:api_key, "k") { ElevenLabsVoices.catalogue } }

    stub_request(:get, ElevenLabsVoices::API_URL).to_return(status: 200, body: "<html>")
    assert_raises(ElevenLabsVoices::Unavailable) { ElevenLabsVoices.stub(:api_key, "k") { ElevenLabsVoices.catalogue } }

    stub_request(:get, ElevenLabsVoices::API_URL).to_timeout
    assert_raises(ElevenLabsVoices::Unavailable) { ElevenLabsVoices.stub(:api_key, "k") { ElevenLabsVoices.catalogue } }
  end

end
