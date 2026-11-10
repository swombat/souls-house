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

  test "an account's own library is read with its own key: the non-premade voices, sorted" do
    account = accounts(:personal_account)
    account.update_columns(eleven_labs_api_key: nil)
    account.update!(eleven_labs_api_key: "acct-key")
    stub = stub_request(:get, ElevenLabsVoices::API_URL).with(headers: { "xi-api-key" => "acct-key" })
      .to_return(status: 200, body: voices_payload)

    voices = ElevenLabsVoices.library(account)

    assert_requested stub
    assert_equal %w[cloned-1 designed-1], voices.map(&:voice_id)
    assert_equal "cloned-1", ElevenLabsVoices.find_in_library(account, "cloned-1").voice_id
    assert_nil ElevenLabsVoices.find_in_library(account, "premade-z")
  end

  test "no key of its own, no library and no request" do
    account = accounts(:personal_account)
    account.update_columns(eleven_labs_api_key: nil)

    assert_equal [], ElevenLabsVoices.library(account)
    assert_equal [], ElevenLabsVoices.library(nil)
    assert_not_requested :get, ElevenLabsVoices::API_URL
  end

  test "the library cache is per account and per key, and never holds the key in its name" do
    store = ActiveSupport::Cache::MemoryStore.new
    one = accounts(:personal_account)
    two = accounts(:team_account)
    one.update!(eleven_labs_api_key: "key-one")
    two.update!(eleven_labs_api_key: "key-two")
    first = stub_request(:get, ElevenLabsVoices::API_URL).with(headers: { "xi-api-key" => "key-one" })
      .to_return(status: 200, body: voices_payload)
    second = stub_request(:get, ElevenLabsVoices::API_URL).with(headers: { "xi-api-key" => "key-two" })
      .to_return(status: 200, body: { voices: [] }.to_json)

    Rails.stub(:cache, store) do
      2.times { ElevenLabsVoices.library(one) }
      assert_equal [], ElevenLabsVoices.library(two)
      assert_requested first, times: 1
      assert_requested second, times: 1

      one.update!(eleven_labs_api_key: "key-two")
      assert_equal [], ElevenLabsVoices.library(one), "a changed key reads afresh"
    end

    names = store.instance_variable_get(:@data).keys
    assert names.any? { |name| name.include?(ElevenLabsVoices::LIBRARY_CACHE_KEY) }
    assert names.none? { |name| name.include?("key-one") || name.include?("key-two") }
  end

  test "offerable? says yes to a standard or an own voice, and is Unavailable only when nothing could say yes" do
    account = accounts(:personal_account)
    own = [ ElevenLabsVoices::Voice.new(voice_id: "own-1", name: "Own", description: "", labels: {}, preview_url: nil) ]
    standard = [ ElevenLabsVoices::Voice.new(voice_id: "std-1", name: "Std", description: "", labels: {}, preview_url: nil) ]
    down = -> { raise ElevenLabsVoices::Unavailable, "503" }

    ElevenLabsVoices.stub(:library, ->(_) { own }) do
      ElevenLabsVoices.stub(:catalogue, standard) do
        assert ElevenLabsVoices.offerable?(account, "std-1")
        assert ElevenLabsVoices.offerable?(account, "own-1")
        assert_not ElevenLabsVoices.offerable?(account, "other")
      end
      ElevenLabsVoices.stub(:catalogue, down) do
        assert ElevenLabsVoices.offerable?(account, "own-1")
        assert_raises(ElevenLabsVoices::Unavailable) { ElevenLabsVoices.offerable?(account, "other") }
      end
    end
    ElevenLabsVoices.stub(:library, ->(_) { raise ElevenLabsVoices::Unavailable, "401" }) do
      ElevenLabsVoices.stub(:catalogue, standard) do
        assert ElevenLabsVoices.offerable?(account, "std-1")
        assert_raises(ElevenLabsVoices::Unavailable) { ElevenLabsVoices.offerable?(account, "own-1") }
      end
    end
  end

end
