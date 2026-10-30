require "test_helper"

class RemoteImageFetchTest < ActiveSupport::TestCase

  include WebMock::API

  teardown { WebMock.reset! }

  PNG = Rails.root.join("test/fixtures/files/test_avatar.png").binread
  PUBLIC = ->(_host) { [ "93.184.216.34" ] }

  test "fetches a public picture and reads its type from the bytes" do
    stub_request(:get, "https://pics.example/me/face.png?x=1").to_return(body: PNG, headers: { "Content-Type" => "text/html" })

    result = RemoteImageFetch.new(resolver: PUBLIC).call("  https://pics.example/me/face.png?x=1 ")

    assert_equal "image/png", result.content_type
    assert_equal "face.png", result.filename
    assert_equal PNG, result.io.read
  end

  test "refuses addresses that resolve anywhere private, before connecting" do
    [ "127.0.0.1", "10.1.2.3", "169.254.169.254", "::1", "fd00::1" ].each do |address|
      error = assert_raises(RemoteImageFetch::Error) do
        RemoteImageFetch.new(resolver: ->(_) { [ address ] }).call("http://sneaky.example/a.png")
      end
      assert_match(/public internet/, error.message, address)
    end
    assert_raises(RemoteImageFetch::Error) { RemoteImageFetch.new.call("http://127.0.0.1/a.png") }
    assert_not_requested :get, /sneaky/
  end

  test "checks the address a redirect points at, too" do
    stub_request(:get, "https://pics.example/a.png").to_return(status: 302, headers: { "Location" => "http://inside.example/secret" })
    resolver = ->(host) { host == "inside.example" ? [ "192.168.1.5" ] : [ "93.184.216.34" ] }

    error = assert_raises(RemoteImageFetch::Error) { RemoteImageFetch.new(resolver:).call("https://pics.example/a.png") }
    assert_match(/public internet/, error.message)
  end

  test "follows a public redirect" do
    stub_request(:get, "https://pics.example/a").to_return(status: 301, headers: { "Location" => "/b.png" })
    stub_request(:get, "https://pics.example/b.png").to_return(body: PNG)

    assert_equal "b.png", RemoteImageFetch.new(resolver: PUBLIC).call("https://pics.example/a").filename
  end

  test "refuses what isn't a picture, other schemes, and failures" do
    stub_request(:get, "https://pics.example/page").to_return(body: "<html>hello</html>")
    stub_request(:get, "https://pics.example/gone.png").to_return(status: 404)

    fetch = RemoteImageFetch.new(resolver: PUBLIC)
    assert_match(/PNG, JPEG/, assert_raises(RemoteImageFetch::Error) { fetch.call("https://pics.example/page") }.message)
    assert_match(/HTTP 404/, assert_raises(RemoteImageFetch::Error) { fetch.call("https://pics.example/gone.png") }.message)
    assert_match(/http/, assert_raises(RemoteImageFetch::Error) { fetch.call("file:///etc/passwd") }.message)
    assert_raises(RemoteImageFetch::Error) { fetch.call("not a url") }
  end

  test "stops reading past 5 MB" do
    stub_request(:get, "https://pics.example/huge.png").to_return(body: PNG + ("x" * (RemoteImageFetch::MAX_BYTES + 1)))

    error = assert_raises(RemoteImageFetch::Error) { RemoteImageFetch.new(resolver: PUBLIC).call("https://pics.example/huge.png") }
    assert_match(/5 MB/, error.message)
  end

end
