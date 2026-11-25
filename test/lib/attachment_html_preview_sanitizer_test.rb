require "test_helper"

class AttachmentHtmlPreviewSanitizerTest < ActiveSupport::TestCase

  test "preserves static markup, inline styles, data images, and static svg" do
    html = <<~HTML
      <!doctype html>
      <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>h1 { color: teal; }</style>
        </head>
        <body>
          <h1 class="title">Quarterly report</h1>
          <table><tr><th colspan="2">Summary</th></tr><tr><td>A</td><td>1</td></tr></table>
          <img src="data:image/png;base64,iVBORw0KGgo=" alt="Chart" width="100">
          <svg viewBox="0 0 10 10"><defs><rect id="box" width="5" height="5"/></defs><use href="#box"/></svg>
        </body>
      </html>
    HTML

    sanitized = AttachmentHtmlPreviewSanitizer.sanitize(html)
    doc = Nokogiri::HTML5.parse(sanitized)

    assert_equal "Quarterly report", doc.at_css("h1.title").text
    assert_includes doc.at_css("style").text, "color: teal"
    assert_equal "data:image/png;base64,iVBORw0KGgo=", doc.at_css("img")["src"]
    assert_equal "Chart", doc.at_css("img")["alt"]
    assert_equal "#box", doc.at_css("use")["href"]
    assert_equal "utf-8", doc.at_css("meta[charset]")["charset"]
    assert_equal "viewport", doc.at_css("meta[name]")["name"]
  end

  test "strips navigation, forms, scripts, noscript payloads, frames, and remote urls while keeping readable text" do
    html = <<~HTML
      <!doctype html>
      <html>
        <head>
          <base href="https://evil.example/">
          <meta http-equiv="refresh" content="0;url=https://evil.example/bounce">
          <link rel="stylesheet" href="https://evil.example/style.css">
        </head>
        <body onload="alert(1)">
          <p>Read <a href="https://evil.example/phish" target="_blank" onclick="alert(2)">the report</a> carefully.</p>
          <map name="m"><area href="https://evil.example/area" coords="0,0,10,10"></map>
          <form action="https://evil.example/submit">
            <p>Static note inside form</p>
            <input type="text" name="secret" formaction="https://evil.example/in">
            <button formaction="https://evil.example/btn">Send</button>
          </form>
          <script>window.location = "https://evil.example";</script>
          <noscript><meta http-equiv="refresh" content="0;url=https://evil.example/noscript"></noscript>
          <iframe src="https://evil.example/frame"></iframe>
          <object data="https://evil.example/obj"></object>
          <embed src="https://evil.example/emb">
          <img src="https://evil.example/pixel.png" srcset="https://evil.example/2x.png 2x" onerror="alert(3)" alt="Remote">
          <svg viewBox="0 0 100 20" xmlns:xlink="http://www.w3.org/1999/xlink">
            <a href="https://evil.example/svg"><text x="0" y="15">SVG link</text></a>
            <a xlink:href="https://evil.example/xlink"><text x="50" y="15">XLink</text></a>
            <use href="https://evil.example/sprite.svg#icon"/>
          </svg>
          <math><mrow href="https://evil.example/math"><mi>x</mi></mrow></math>
        </body>
      </html>
    HTML

    sanitized = AttachmentHtmlPreviewSanitizer.sanitize(html)
    doc = Nokogiri::HTML5.parse(sanitized)

    assert_includes doc.text, "Read the report carefully."
    assert_includes doc.text, "Static note inside form"
    assert_includes doc.text, "SVG link"
    assert_includes doc.text, "XLink"

    %w[a area base link form input button script noscript iframe object embed math].each do |tag|
      assert_empty doc.css(tag), "Expected <#{tag}> to be removed"
    end
    assert_empty doc.css("meta[http-equiv]"), "Expected meta[http-equiv] to be removed"
    assert_nil doc.at_css("body")["onload"]
    assert_nil doc.at_css("img")["src"]
    assert_nil doc.at_css("img")["srcset"]
    assert_nil doc.at_css("img")["onerror"]
    assert_nil doc.at_css("use")["href"]
    assert_not_includes sanitized, "evil.example"
    assert_not_includes sanitized, "window.location"
  end

  test "decodes windows-1252 documents cleanly to utf-8" do
    raw = "<!doctype html><html><head><meta charset=\"windows-1252\"></head><body><p>Caf\xE9 \x93hello\x94</p></body></html>".b
    sanitized = AttachmentHtmlPreviewSanitizer.sanitize(raw)

    assert_equal Encoding::UTF_8, sanitized.encoding
    assert sanitized.valid_encoding?
    assert_includes sanitized, "Café \u201Chello\u201D"
    assert_includes sanitized, 'charset="utf-8"'
  end

  test "rejects html larger than MAX_BYTES" do
    oversized = "a" * (AttachmentHtmlPreviewSanitizer::MAX_BYTES + 1)
    assert_raises(AttachmentHtmlPreviewSanitizer::TooLarge) do
      AttachmentHtmlPreviewSanitizer.sanitize(oversized)
    end
  end

end
