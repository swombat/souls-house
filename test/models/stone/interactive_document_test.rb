require "test_helper"

class Stone::InteractiveDocumentTest < ActiveSupport::TestCase

  test "accepts inline JavaScript and local score controls without weakening static policy" do
    html = '<!doctype html><html><head><title>Sound</title></head><body><label for="score">Score</label><textarea id="score"></textarea><button type="button">Play</button><canvas width="20" height="20"></canvas><script>document.querySelector("button").onclick = () => new AudioContext();</script></body></html>'
    assert_equal html, Stone::InteractiveDocument.new(html).validate!
    assert_raises(Stone::Document::Invalid) { Stone::Document.new(html).validate! }
  end

  test "rejects external scripts links forms frames file inputs and event attributes" do
    [
      '<script src="https://example.com/a.js"></script>',
      '<a href="https://example.com">Go</a>',
      '<form action="/"><button>Send</button></form>',
      '<iframe src="/"></iframe>', '<input type="file">',
      '<button onclick="alert(1)">Go</button>',
      '<meta http-equiv="refresh" content="0;url=https://example.com">'
    ].each do |fragment|
      assert_raises(Stone::Document::Invalid, fragment) do
        Stone::InteractiveDocument.new("<!doctype html><html><head><title>Test</title></head><body>#{fragment}</body></html>").validate!
      end
    end
  end

end
