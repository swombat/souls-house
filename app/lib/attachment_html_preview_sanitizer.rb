require "nokogiri"

# Parser-based allowlist sanitizer for rendered HTML attachment previews.
# Preserves static document markup, inline styles, data: images, and static SVG
# while stripping navigation (links, forms, meta refresh, base, frames, active
# elements, and remote URLs) so a rendered preview cannot phone home or navigate
# away inside the preview dialog or when opened directly.
class AttachmentHtmlPreviewSanitizer

  class TooLarge < StandardError; end
  class Invalid < StandardError; end

  MAX_BYTES = 5 * 1024 * 1024
  MAX_NODES = 50_000
  MAX_DEPTH = 128

  HTML_NAMESPACE = "http://www.w3.org/1999/xhtml".freeze
  SVG_NAMESPACE = "http://www.w3.org/2000/svg".freeze

  HTML_ELEMENTS = %w[
    html head body title meta style
    main header footer section article aside nav address hgroup search
    div span p h1 h2 h3 h4 h5 h6 br wbr hr pre code blockquote q cite abbr dfn
    strong em b i u s small sub sup mark del ins time kbd samp var bdi bdo ruby rt rp data
    ul ol li dl dt dd menu
    figure figcaption img picture
    table caption colgroup col thead tbody tfoot tr th td
    details summary dialog meter progress
  ].freeze

  HTML_GLOBAL_ATTRIBUTES = %w[id class style title lang dir role hidden].freeze

  HTML_ATTRIBUTES = {
    "meta" => %w[charset name content],
    "style" => %w[type media],
    "img" => %w[src alt width height loading decoding],
    "table" => %w[border cellpadding cellspacing width],
    "colgroup" => %w[span],
    "col" => %w[span],
    "th" => %w[colspan rowspan headers scope abbr align valign width],
    "td" => %w[colspan rowspan headers align valign width],
    "tr" => %w[align valign],
    "ol" => %w[start reversed type],
    "li" => %w[value],
    "time" => %w[datetime],
    "del" => %w[datetime],
    "ins" => %w[datetime],
    "details" => %w[open],
    "dialog" => %w[open],
    "meter" => %w[value min max low high optimum],
    "progress" => %w[value max],
    "data" => %w[value]
  }.freeze

  SVG_ELEMENTS = %w[
    svg g defs symbol style title desc path rect circle ellipse line polyline polygon
    text tspan linearGradient radialGradient stop clipPath mask use
  ].freeze

  SVG_GLOBAL_ATTRIBUTES = %w[
    id class style role fill fill-opacity fill-rule stroke stroke-width
    stroke-opacity stroke-linecap stroke-linejoin stroke-miterlimit
    stroke-dasharray stroke-dashoffset opacity transform vector-effect
    clip-path clip-rule mask color display visibility
    font-family font-size font-weight font-style text-anchor dominant-baseline
  ].freeze

  SVG_ATTRIBUTES = {
    "svg" => %w[xmlns width height viewBox preserveAspectRatio x y],
    "symbol" => %w[viewBox preserveAspectRatio x y width height],
    "style" => %w[type media],
    "path" => %w[d pathLength],
    "rect" => %w[x y width height rx ry pathLength],
    "circle" => %w[cx cy r pathLength],
    "ellipse" => %w[cx cy rx ry pathLength],
    "line" => %w[x1 y1 x2 y2 pathLength],
    "polyline" => %w[points pathLength],
    "polygon" => %w[points pathLength],
    "text" => %w[x y dx dy rotate textLength lengthAdjust],
    "tspan" => %w[x y dx dy rotate textLength lengthAdjust],
    "linearGradient" => %w[x1 y1 x2 y2 gradientUnits gradientTransform spreadMethod],
    "radialGradient" => %w[cx cy r fx fy fr gradientUnits gradientTransform spreadMethod],
    "stop" => %w[offset stop-color stop-opacity],
    "clipPath" => %w[clipPathUnits],
    "mask" => %w[x y width height maskUnits maskContentUnits],
    "use" => %w[href x y width height]
  }.freeze

  # Elements whose entire subtree is removed rather than unwrapped, including
  # rawtext/parser-differential elements (script, noscript, noembed, noframes,
  # xmp), embedded/navigation containers, and interactive form controls.
  DROP_ELEMENTS = %w[
    script noscript noembed noframes xmp
    iframe frame frameset object embed applet portal
    base link template area
    audio video source track canvas
    input button select option optgroup textarea datalist keygen
    foreignObject image feImage animate animateMotion animateTransform set mpath handler listener
  ].freeze

  ALLOWED_META_NAMES = %w[viewport description color-scheme author].freeze
  SAFE_DATA_IMAGE_URI = /\Adata:image\/(?:png|jpeg|jpg|gif|webp|avif|bmp|x-icon|vnd\.microsoft\.icon|svg\+xml);/i
  LOCAL_FRAGMENT = /\A#[A-Za-z_][A-Za-z0-9_.-]*\z/

  def self.sanitize(raw_html)
    new(raw_html).sanitize
  end

  def initialize(raw_html)
    @raw_html = raw_html
    @node_count = 0
  end

  def sanitize
    bytes = @raw_html.to_s.b
    raise TooLarge, "HTML exceeds #{MAX_BYTES} bytes" if bytes.bytesize > MAX_BYTES

    utf8 = self.class.decode_to_utf8(bytes)
    document = Nokogiri::HTML5.parse(utf8, nil, "UTF-8", max_tree_depth: MAX_DEPTH)
    sanitize_children(document)
    document.to_html
  rescue Nokogiri::XML::SyntaxError, ArgumentError, EncodingError => error
    raise Invalid, error.message
  end

  def self.decode_to_utf8(raw_bytes)
    bytes = raw_bytes.to_s.b
    bytes = bytes.byteslice(3..) if bytes.start_with?("\xEF\xBB\xBF".b)

    utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
    return utf8 if utf8.valid_encoding?

    declared = detect_declared_charset(bytes)
    encoding = resolve_encoding(declared)
    if encoding
      begin
        return bytes.dup.force_encoding(encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      rescue Encoding::ConverterNotFoundError
        # Ruby recognizes some encodings (e.g. dummy encodings such as UTF-7)
        # that have no UTF-8 converter; fall back to Windows-1252 below.
      end
    end

    bytes.dup.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
  end

  def self.detect_declared_charset(bytes)
    head = bytes.byteslice(0, 2048).to_s
    match = head.match(/<meta\b[^>]*\bcharset\s*=\s*["']?\s*([A-Za-z0-9._-]+)/i)
    match ||= head.match(/<meta\b[^>]*\bcontent\s*=\s*["'][^"']*charset\s*=\s*([A-Za-z0-9._-]+)/i)
    match&.[](1)
  end

  def self.resolve_encoding(name)
    return nil if name.nil? || name.empty?

    Encoding.find(name)
  rescue ArgumentError
    nil
  end

  private

  def sanitize_children(parent)
    parent.children.to_a.each do |child|
      sanitize_node(child)
    end
  end

  def sanitize_node(node)
    @node_count += 1
    raise TooLarge, "HTML exceeds #{MAX_NODES} nodes" if @node_count > MAX_NODES

    if node.element?
      sanitize_element(node)
    elsif node.comment? || node.processing_instruction?
      node.remove
    end
  end

  def sanitize_element(node)
    namespace = node.namespace&.href
    if namespace == SVG_NAMESPACE
      svg = true
    elsif namespace.nil? || namespace == HTML_NAMESPACE
      svg = false
    else
      node.remove
      return
    end

    name = node.name
    if DROP_ELEMENTS.include?(name)
      node.remove
      return
    end

    allowed_elements = svg ? SVG_ELEMENTS : HTML_ELEMENTS
    unless allowed_elements.include?(name)
      unwrap_element(node)
      return
    end

    if !svg && name == "meta"
      sanitize_meta(node)
      return
    end

    sanitize_attributes(node, svg:)
    sanitize_children(node)
  end

  def unwrap_element(node)
    sanitize_children(node)
    node.children.to_a.each { |child| node.add_previous_sibling(child) }
    node.remove
  end

  def sanitize_meta(node)
    if node["http-equiv"]
      node.remove
      return
    end

    if node["charset"]
      node.attribute_nodes.to_a.each(&:remove)
      node["charset"] = "utf-8"
      return
    end

    meta_name = node["name"].to_s.downcase
    meta_content = node["content"]
    if ALLOWED_META_NAMES.include?(meta_name) && meta_content
      node.attribute_nodes.to_a.each do |attr|
        attr.remove unless %w[name content].include?(attr.name) && attr.namespace.nil?
      end
    else
      node.remove
    end
  end

  def sanitize_attributes(node, svg:)
    global = svg ? SVG_GLOBAL_ATTRIBUTES : HTML_GLOBAL_ATTRIBUTES
    specific = (svg ? SVG_ATTRIBUTES : HTML_ATTRIBUTES).fetch(node.name, [])

    node.attribute_nodes.to_a.each do |attribute|
      attr_name = attribute.name
      value = attribute.value.to_s

      if attribute.namespace
        unless svg && node.name == "svg" && attr_name == "xmlns" && value == SVG_NAMESPACE
          attribute.remove
        end
        next
      end

      aria = !svg && attr_name.match?(/\Aaria-[a-z-]+\z/)
      unless global.include?(attr_name) || specific.include?(attr_name) || aria
        attribute.remove
        next
      end

      if !svg && node.name == "img" && attr_name == "src"
        attribute.remove unless value.strip.match?(SAFE_DATA_IMAGE_URI)
      elsif svg && node.name == "use" && attr_name == "href"
        attribute.remove unless value.strip.match?(LOCAL_FRAGMENT)
      elsif svg && node.name == "svg" && attr_name == "xmlns"
        attribute.remove unless value == SVG_NAMESPACE
      end
    end
  end

end
