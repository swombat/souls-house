# This policy is a pure object: no Rails boot, credentials, database or network.
require "minitest/autorun"
require "zlib"
require_relative "../../../app/models/stone/document"

class StoneDocumentTest < Minitest::Test

  def document(body, head: "")
    "<!doctype html><html><head><meta charset=\"utf-8\">#{head}</head><body>#{body}</body></html>"
  end

  def assert_invalid(html, message = nil)
    error = assert_raises(Stone::Document::Invalid) { Stone::Document.new(html).validate! }
    assert_kind_of Array, error.errors
    refute_empty error.errors
    assert error.errors.all? { |diagnostic| diagnostic.is_a?(String) && diagnostic.length <= 240 }
    assert_match message, error.errors.join(" ") if message
    error
  end

  def data_image(format, image = Vips::Image.black(2, 3))
    type = format == "jpg" ? "jpeg" : format
    encoded = image.public_send("#{type}save_buffer")
    "data:image/#{type};base64,#{Base64.strict_encode64(encoded)}"
  end

  def test_returns_original_utf8_document_without_normalizing
    html = "<!doctype html><h1 lang='es'>Una página — piedra 🪨</h1>"
    assert_same html, Stone::Document.new(html).validate!
    assert_operator Stone::Document::POLICY_VERSION, :>=, 1
  end

  def test_accepts_tables_accessibility_metadata_and_css_animation
    html = document(<<~HTML, head: <<~HEAD)
      <main aria-label="Report" class="card" style="--accent: oklch(70% .2 20); color: var(--accent)">
        <h1>A report</h1><details open><summary>Data</summary>
        <table><caption>Results</caption><colgroup><col span="2"></colgroup>
          <thead><tr><th scope="col">Name</th><th scope="col">Value</th></tr></thead>
          <tbody><tr><td>A</td><td>2</td></tr></tbody>
        </table></details><p><strong>Done</strong> <time datetime="2026-10-03">today</time></p>
      </main>
    HTML
      <title>Report</title><meta name="viewport" content="width=device-width, initial-scale=1">
      <style>@media (prefers-reduced-motion: no-preference) {
        .card { animation: pulse 2s infinite; background: linear-gradient(45deg, red, blue); }
      } @keyframes pulse { from { transform: scale(1); } to { transform: scale(1.1); } }</style>
    HEAD
    assert_same html, Stone::Document.new(html).validate!
  end

  def test_accepts_static_svg_with_local_geometry_and_paint_references
    html = document(<<~HTML, head: '<style>.paint { fill: url("#gradient"); }</style>')
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
        <title>A circle</title><desc>Inline SVG</desc><defs>
          <linearGradient id="gradient"><stop offset="0" stop-color="red"></stop>
            <stop offset="1" stop-color="blue"></stop></linearGradient>
          <clipPath id="clip"><rect width="50" height="50"></rect></clipPath>
          <circle id="circle" cx="20" cy="20" r="10"></circle>
        </defs><use href="#circle" class="paint" clip-path="url(#clip)"></use>
        <path d="M 0 0 L 100 100" style="stroke: url(\\23 gradient); fill: none"></path>
        <text x="2" y="40"><tspan>hello</tspan></text>
      </svg>
    HTML
    assert_same html, Stone::Document.new(html).validate!
  end

  def test_accepts_real_png_jpeg_and_webp_images
    %w[png jpg webp].each do |format|
      html = document("<img alt='sample' width='2' height='3' src='#{data_image(format)}'>")
      assert_same html, Stone::Document.new(html).validate!
    end
  end

  def test_rejects_script_event_handlers_and_unknown_markup
    [
      "<script>alert(1)</script>", "<SCRIPT src='https://example.test/x.js'></SCRIPT>",
      "<p onclick='alert(1)'>click</p>", "<div onpointerenter='alert(1)'></div>",
      "<img src='x' oNerror='alert(1)'>", "<custom-element>no</custom-element>",
      "<template><script>alert(1)</script></template>", "<noscript><img src=x></noscript>",
      "<canvas></canvas>"
    ].each { |body| assert_invalid(document(body)) }
  end

  def test_rejects_navigation_forms_and_remote_html_resources
    [
      "<a href='https://example.test'>go</a>", "<a href='#x'>local navigation</a>",
      "<form action='https://example.test'><input name='secret'></form>",
      "<button formaction='https://example.test'>go</button>",
      "<iframe srcdoc='<p>inner</p>'></iframe>", "<object data='x'></object>",
      "<embed src='x'>", "<video poster='https://example.test/x'></video>",
      "<audio src='x'></audio>", "<img src='https://example.test/image.png'>",
      "<img src='//example.test/image.png'>", "<img src='/image.png'>",
      "<img srcset='data:image/png;base64,eA== 1x'>",
      "<div background='https://example.test/x'></div>",
      "<div popover>no</div>", "<div contenteditable>no</div>"
    ].each { |body| assert_invalid(document(body)) }
    [
      "<meta http-equiv='refresh' content='0;url=https://example.test'>",
      "<meta http-equiv='Content-Security-Policy' content=\"default-src *\">",
      "<base href='https://example.test'>", "<link rel='stylesheet' href='https://example.test/x'>",
      "<link rel='prefetch' href='https://example.test/x'>",
      "<meta charset='windows-1252'>", "<meta name='referrer' content='unsafe-url'>"
    ].each { |head| assert_invalid(document("<p>body</p>", head: head)) }
  end

  def test_rejects_hostile_svg_and_namespace_edges
    [
      "<svg><script>alert(1)</script></svg>",
      "<svg onload='alert(1)'><circle r='1'></circle></svg>",
      "<svg><foreignObject><div>foreign</div></foreignObject></svg>",
      "<svg><image href='https://example.test/x'></image></svg>",
      "<svg><a href='https://example.test'>go</a></svg>",
      "<svg><animate attributeName='href' values='javascript:alert(1)'></animate></svg>",
      "<svg><set attributeName='onload' to='alert(1)'></set></svg>",
      "<svg><use href='https://example.test/x.svg#shape'></use></svg>",
      "<svg><use href='data:image/svg+xml,x'></use></svg>",
      "<svg><use href='javascript:alert(1)'></use></svg>",
      "<svg><use xlink:href='#shape'></use><path id='shape' d='M0 0'></path></svg>",
      "<svg><linearGradient href='https://example.test/g'></linearGradient></svg>",
      "<svg><filter><feImage href='https://example.test/x'></feImage></filter></svg>",
      "<svg><style>@import 'https://example.test/x';</style></svg>",
      "<math><mtext><img src=x onerror=alert(1)></mtext></math>",
      "<svg><desc><div onmouseover='alert(1)'>integration point</div></desc></svg>",
      "<svg xmlns='http://example.test/evil'><path></path></svg>",
      "<div xmlns='http://www.w3.org/2000/svg'>fake namespace</div>",
      "<svg><g xml:base='https://example.test'><use href='#x'></use></g></svg>"
    ].each { |body| assert_invalid(document(body)) }
  end

  def test_rejects_invalid_or_recursive_svg_references
    [
      "<svg><use href='#missing'></use></svg>",
      "<svg><use id='recursive' href='#recursive'></use></svg>",
      "<svg><g id='group'><use href='#group'></use></g></svg>",
      "<svg><path fill='url(https://example.test/p)' d='M0 0'></path></svg>",
      "<svg><path fill='url(&#104;ttps://example.test/p)' d='M0 0'></path></svg>",
      "<svg><path id='p' fill='url(#p)' d='M0 0'></path></svg>",
      "<svg><path id='p'></path></svg><svg><use href='#p'></use></svg>",
      "<svg><use href='#shape%00'></use></svg>"
    ].each { |body| assert_invalid(document(body)) }
  end

  def test_css_tokenizer_rejects_obfuscated_network_fetches_and_imports
    [
      "@import 'https://example.test/style';", "@IMPORT/**/url(https://example.test/style);",
      "@\\69mport '\\68ttps://example.test/style';",
      "p{background:url(https://example.test/x)}", "p{background:URL('//example.test/x')}",
      "p{background:u\\72l(\\68 ttps://example.test/x)}",
      "p{background:url(/**/https://example.test/x)}",
      "p{background:url(data:image/png;base64,eA==)}", "p{background:url(/relative)}",
      "p{background:image-set('https://example.test/x' 1x)}",
      "p{background:-webkit-image-set('https://example.test/x' 1x)}",
      "p{background:i\\6d age-set('https://example.test/x' 1x)}",
      "p{background:image('https://example.test/x')}", "p{--fetch:url(https://example.test/x)}",
      "p{background:var(--fetch,url(https://example.test/x))}",
      "@font-face{font-family:x;src:url(https://example.test/font)}",
      "p{behavior:url(https://example.test/x)}", "p{width:expression(alert(1))}",
      "p{background:attr(data-image type(<url>))}", "p{background:url('unterminated)}"
    ].each do |css|
      assert_invalid(document("<p>body</p>", head: "<style>#{css}</style>"))
      assert_invalid(document("<p style=\"#{css.gsub('"', '&quot;')}\">body</p>"))
    end
  end

  def test_css_plain_strings_are_not_mistaken_for_network_requests
    html = document("<p>text</p>", head: "<style>p::after { content: 'https://example.test/words url(foo) @import'; }</style>")
    assert_same html, Stone::Document.new(html).validate!
  end

  def test_rejects_non_raster_and_forged_or_truncated_image_data
    png = Vips::Image.black(2, 2).pngsave_buffer
    [
      "data:image/svg+xml;base64,#{Base64.strict_encode64('<svg></svg>')}",
      "data:image/gif;base64,#{Base64.strict_encode64('GIF89a')}",
      "data:image/jpeg;base64,#{Base64.strict_encode64(png)}",
      "data:image/png;base64,#{Base64.strict_encode64('<script>alert(1)</script>')}",
      "data:image/png;base64,#{Base64.strict_encode64(png.byteslice(0, 40))}",
      "data:image/webp;base64,#{Base64.strict_encode64('RIFFxxxxWEBPjunk')}",
      "data:image/png;base64,%%%=", "data:image/png;base64,eA=",
      "data:image/png;foo=bar;base64,#{Base64.strict_encode64(png)}",
      "data:image/png;base64,#{Base64.strict_encode64(png)}\n"
    ].each { |src| assert_invalid(document("<img src='#{src}'>")) }
  end

  def test_rejects_image_dimension_pixel_and_byte_bombs_before_full_decode
    [
      Vips::Image.black(Stone::Document::MAX_IMAGE_DIMENSION + 1, 1),
      Vips::Image.black(4001, 4000)
    ].each do |image|
      assert_invalid(document("<img src='#{data_image('png', image)}'>"), /pixel|dimensions/)
    end
    src = "data:image/png;base64,#{Base64.strict_encode64('x' * (Stone::Document::MAX_IMAGE_BYTES + 1))}"
    assert_invalid(document("<img src='#{src}'>"), /byte/)
    src = data_image("png")
    assert_invalid(document(("<img src='#{src}'>" * (Stone::Document::MAX_IMAGES + 1))), /Too many images/)
  end

  def test_rejects_animated_webp_and_apng_even_when_raster_loader_ignores_frames
    image = Vips::Image.black(2, 3).join(Vips::Image.black(2, 3) + 255, :vertical)
    webp = image.webpsave_buffer(page_height: 3, lossless: true)
    src = "data:image/webp;base64,#{Base64.strict_encode64(webp)}"
    assert_invalid(document("<img src='#{src}'>"), /Animated/)

    png = Vips::Image.black(2, 3).pngsave_buffer
    chunks = [ [ "acTL", [ 1, 0 ].pack("NN") ],
      [ "fcTL", [ 0, 2, 3, 0, 0, 1, 10, 0, 0 ].pack("NNNNNnnCC") ] ].map do |name, payload|
      [ payload.bytesize ].pack("N") + name + payload + [ Zlib.crc32(name + payload) ].pack("N")
    end.join
    apng = png.byteslice(0, 33) + chunks + png.byteslice(33..)
    # A real raster decode succeeds; ignoring the extra animation chunks must
    # not make this acceptable for our single-frame image budget.
    assert_equal 2, Vips::Image.pngload_buffer(apng).width
    src = "data:image/png;base64,#{Base64.strict_encode64(apng)}"
    assert_invalid(document("<img src='#{src}'>"), /Animated/)
  end

  def test_enforces_aggregate_image_pixel_budget
    src = data_image("png", Vips::Image.black(4000, 4000))
    assert_invalid(document("<img src='#{src}'>" * 3), /pixel budget/)
  end

  def test_bounds_attribute_count_and_css_token_count
    attributes = (1..100).map { |index| "aria-a#{index}='x'" }.join(" ")
    assert_invalid(document("<div #{attributes}></div>"), /attributes|parsing/)
    css = "p{" + ("a:0;" * 25_001) + "}"
    assert_invalid(document("<p>body</p>", head: "<style>#{css}</style>"), /token limit/)
  end

  def test_rejects_html5_repairs_that_could_hide_original_markup
    [
      "<!doctype html><div class='safe' CLASS='bad'>duplicate</div>",
      "<!doctype html><table><div>foster parenting</div></table>",
      "<!doctype html></ignored><p>discarded token</p>",
      "<!doctype html><div/>self closing nonvoid",
      "<!doctype html><svg><![CDATA[</svg><script>alert(1)</script>]]></svg><p onclick=x>x</p>",
      "<!DOCTYPE html PUBLIC 'public-id' 'https://example.test/dtd'><p>x</p>",
      "<p>missing doctype</p>", "<!doctype svg><svg></svg>"
    ].each { |html| assert_invalid(html) }
  end

  def test_rejects_invalid_encoding_and_bounds_diagnostics_and_work
    assert_invalid(nil, /UTF-8/)
    assert_invalid("\xff".b.force_encoding(Encoding::UTF_8), /UTF-8/)
    assert_invalid("<!doctype html><p>\0</p>", /null/)
    assert_invalid(" " * (Stone::Document::MAX_BYTES + 1), /5 MiB/)
    assert_invalid(document("<div>" * 100 + "</div>" * 100), /depth|parsing/)
    assert_invalid(document("<br>" * Stone::Document::MAX_NODES), /node limit/)
    assert_invalid(document("<p style='color:red;'>" + "x" + "</p>", head: "<style>#{" " * (Stone::Document::MAX_CSS_BYTES + 1)}</style>"), /CSS.*byte/)
    error = assert_invalid(document("<script>x</script>" * 1000))
    assert_operator error.errors.length, :<=, Stone::Document::MAX_ERRORS
    assert_operator error.message.length, :<=, Stone::Document::MAX_ERRORS * 242
  end

  def test_duplicate_ids_and_repeat_validation_fail_closed
    validator = Stone::Document.new(document("<p id='same'>x</p><div id='same'>y</div>"))
    2.times { assert_raises(Stone::Document::Invalid) { validator.validate! } }
    html = document("<p>fine</p>")
    validator = Stone::Document.new(html)
    2.times { assert_same html, validator.validate! }
  end

end
