require "test_helper"

# The HTTP contract PyannoteClient keeps with pyannoteAI (spec §2, §9),
# checked without credentials: request shapes, error mapping, and that no
# print or audio URL ever appears in an error.
class PyannoteClientTest < ActiveSupport::TestCase

  include WebMock::API

  teardown { WebMock.reset! }

  def client = PyannoteClient.new

  def with_key(&) = PyannoteClient.stub(:api_key, "pk_test", &)

  test "voiceprint posts the sample URL with the bearer key and returns the job id" do
    request = stub_request(:post, "https://api.pyannote.ai/v1/voiceprint")
      .with(body: { url: "https://storage.example/sample.wav" }.to_json,
            headers: { "Authorization" => "Bearer pk_test", "Content-Type" => "application/json" })
      .to_return(status: 200, body: { jobId: "job-1", status: "created" }.to_json)

    with_key { assert_equal "job-1", client.voiceprint(url: "https://storage.example/sample.wav") }
    assert_requested request
  end

  test "identify sends opaque labels, exclusive matching, the threshold and the speaker ceiling" do
    stub_request(:post, "https://api.pyannote.ai/v1/identify").with do |req|
      body = JSON.parse(req.body)
      body["voiceprints"] == [ { "label" => "v1", "voiceprint" => "PRINT" } ] &&
        body["matching"] == { "threshold" => 50, "exclusive" => true } && body["maxSpeakers"] == 3 && body["model"] == "precision-2"
    end.to_return(status: 200, body: { jobId: "job-2" }.to_json)

    with_key do
      assert_equal "job-2", client.identify(url: "https://storage.example/rec.m4a",
        voiceprints: [ { label: "v1", voiceprint: "PRINT" } ], threshold: 50, num_speakers: 3)
    end
  end

  test "job polls by id" do
    stub_request(:get, "https://api.pyannote.ai/v1/jobs/job-1").to_return(status: 200, body: { status: "running" }.to_json)
    with_key { assert_equal "running", client.job("job-1")["status"] }
  end

  test "errors are our wording and a status code; prints and URLs never leak" do
    stub_request(:post, "https://api.pyannote.ai/v1/identify")
      .to_return(status: 400, body: { message: "bad voiceprint SECRETPRINT at https://storage.example/rec.m4a" }.to_json)
    error = with_key do
      assert_raises(PyannoteClient::PermanentError) do
        client.identify(url: "https://storage.example/rec.m4a", voiceprints: [ { label: "v1", voiceprint: "SECRETPRINT" } ], threshold: 50)
      end
    end
    assert_equal "pyannote refused the request (400)", error.message

    [ 429, 503 ].each do |status|
      stub_request(:get, "https://api.pyannote.ai/v1/jobs/j").to_return(status:, body: "{}")
      with_key { assert_raises(PyannoteClient::TransientError) { client.job("j") } }
    end
  end

  test "a success without a job id, or an unreadable body, is transient, not a crash" do
    stub_request(:post, "https://api.pyannote.ai/v1/voiceprint").to_return(status: 200, body: "[]")
    with_key { assert_raises(PyannoteClient::TransientError) { client.voiceprint(url: "u") } }
    stub_request(:post, "https://api.pyannote.ai/v1/voiceprint").to_return(status: 200, body: "not json")
    with_key { assert_raises(PyannoteClient::TransientError) { client.voiceprint(url: "u") } }
  end

  test "without a key nothing is sent" do
    PyannoteClient.stub(:api_key, nil) do
      assert_raises(PyannoteClient::PermanentError) { client.voiceprint(url: "u") }
    end
    assert_not_requested :any, /pyannote/
  end

end
