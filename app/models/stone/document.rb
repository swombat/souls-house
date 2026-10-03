require "base64"
require "nokogiri"
require "crass"
require "vips"

class Stone
  # A deliberately small, static HTML vocabulary, not a sanitizer. Keep the
  # original bytes: do not serialize a validated DOM back into a different HTML
  # parsing context. Serve only as UTF-8 text/html, with the viewer's restrictive
  # CSP and iframe sandbox (no scripts, same-origin, forms or navigation grants).
  # HTML5 parsing and CSS tokenization are secondary checks, not that boundary.
  class Document

    POLICY_VERSION = 1
    MAX_BYTES = 5 * 1024 * 1024
    MAX_NODES = 20_000
    MAX_DEPTH = 64
    MAX_ATTRIBUTES = 64
    MAX_ERRORS = 20
    MAX_CSS_BYTES = 512 * 1024
    MAX_CSS_TOKENS = 100_000
    MAX_IMAGE_BYTES = 2 * 1024 * 1024
    MAX_IMAGE_TOTAL_BYTES = 4 * 1024 * 1024
    MAX_IMAGES = 32
    MAX_IMAGE_DIMENSION = 8192
    MAX_IMAGE_PIXELS = 16_000_000
    MAX_TOTAL_IMAGE_PIXELS = 32_000_000

    SVG_NAMESPACE = "http://www.w3.org/2000/svg"
    HTML_NAMESPACE = "http://www.w3.org/1999/xhtml"
    HTML_ELEMENTS = %w[
      html head body title meta style main header footer section article aside nav
      div span p h1 h2 h3 h4 h5 h6 br hr pre code blockquote q cite abbr
      strong em b i u s small sub sup mark del ins time kbd samp var
      ul ol li dl dt dd figure figcaption img table caption colgroup col
      thead tbody tfoot tr th td details summary
    ].freeze
    HTML_GLOBAL_ATTRIBUTES = %w[id class style title lang dir role].freeze
    HTML_ATTRIBUTES = {
      "meta" => %w[charset name content],
      "style" => %w[type media],
      "img" => %w[src alt width height loading decoding],
      "table" => %w[border],
      "colgroup" => %w[span],
      "col" => %w[span],
      "th" => %w[colspan rowspan headers scope abbr],
      "td" => %w[colspan rowspan headers],
      "ol" => %w[start reversed type],
      "li" => %w[value],
      "time" => %w[datetime],
      "del" => %w[datetime],
      "ins" => %w[datetime],
      "details" => %w[open]
    }.freeze
    SVG_ELEMENTS = %w[
      svg g defs title desc path rect circle ellipse line polyline polygon
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
    SVG_USE_TARGETS = %w[path rect circle ellipse line polyline polygon].freeze
    SVG_PAINT_TARGETS = %w[linearGradient radialGradient clipPath mask].freeze
    CSS_AT_RULES = %w[media supports keyframes -webkit-keyframes layer container starting-style].freeze
    # Functions that cannot fetch resources. Unknown functions fail closed,
    # including image-set("https://..."), image(), src(), attr() and paint().
    CSS_FUNCTIONS = %w[
      var calc min max clamp env rgb rgba hsl hsla hwb lab lch oklab oklch
      color color-mix light-dark linear-gradient radial-gradient conic-gradient
      repeating-linear-gradient repeating-radial-gradient repeating-conic-gradient
      translate translateX translateY translateZ translate3d scale scaleX scaleY
      scaleZ scale3d rotate rotateX rotateY rotateZ rotate3d skew skewX skewY
      matrix matrix3d perspective cubic-bezier steps linear
      blur brightness contrast grayscale hue-rotate invert opacity saturate sepia
      drop-shadow counter counters repeat minmax fit-content
      not is where has nth-child nth-last-child nth-of-type nth-last-of-type
      selector style sin cos tan asin acos atan atan2 pow sqrt hypot log exp
      abs sign round mod rem
    ].map(&:downcase).freeze
    FRAGMENT = /\A#[A-Za-z_][A-Za-z0-9_.-]*\z/
    IMAGE_TYPES = {
      "png" => [ "\x89PNG\r\n\x1a\n".b, :pngload_buffer ],
      "jpeg" => [ "\xff\xd8\xff".b, :jpegload_buffer ],
      "webp" => [ "RIFF".b, :webpload_buffer ]
    }.freeze

    class Invalid < StandardError

      attr_reader :errors

      def initialize(errors)
        @errors = errors.map { |error| error.to_s[0, 240].freeze }.freeze
        super(@errors.join("; "))
      end

    end

    def initialize(html)
      @html = html
    end

    def validate!
      @errors = []
      @ids = {}
      @references = []
      @css_bytes = @css_tokens = @image_bytes = @image_pixels = @images = 0
      fail_with("HTML must be a valid UTF-8 string") unless @html.is_a?(String) &&
        @html.encoding == Encoding::UTF_8 && @html.valid_encoding?
      fail_with("HTML exceeds the 5 MiB limit") if @html.bytesize > MAX_BYTES
      fail_with("HTML must not contain null characters") if @html.include?("\0")

      document = Nokogiri::HTML5.parse(@html, nil, "UTF-8",
        max_errors: MAX_ERRORS, max_tree_depth: MAX_DEPTH, max_attributes: MAX_ATTRIBUTES)
      # Missing doctype, duplicate attributes, discarded tokens, namespace
      # integration errors, etc. must not be silently repaired into acceptance.
      document.errors.each { |error| add_error("Invalid HTML5: #{error.str1 || error.message.lines.first}") }
      dtd = document.internal_subset
      add_error("An HTML5 <!doctype html> without public/system identifiers is required") unless
        dtd && dtd.name == "html" && !dtd.external_id && !dtd.system_id
      raise Invalid, @errors unless @errors.empty?

      count = 0
      document.traverse do |node|
        count += 1
        fail_with("HTML exceeds the #{MAX_NODES} node limit") if count > MAX_NODES
        validate_element(node) if node.element?
        break if @errors.length >= MAX_ERRORS
      end
      validate_references if @errors.length < MAX_ERRORS
      raise Invalid, @errors unless @errors.empty?
      @html
    rescue Nokogiri::XML::SyntaxError, ArgumentError => error
      fail_with("HTML parsing failed: #{error.message.lines.first}")
    end

    private

    def validate_element(node)
      namespace = node.namespace&.href
      if namespace == SVG_NAMESPACE
        svg = true
        allowed_elements = SVG_ELEMENTS
      elsif namespace.nil? || namespace == HTML_NAMESPACE
        svg = false
        allowed_elements = HTML_ELEMENTS
      else
        return add_error("Unsupported namespace on #{node.name}")
      end
      return add_error("Unsupported element: #{node.name}") unless allowed_elements.include?(node.name)
      if svg && %w[title desc].include?(node.name) && node.element_children.any?
        add_error("SVG #{node.name} must contain text only")
      end

      node.attribute_nodes.each do |attribute|
        name = attribute.name
        value = attribute.value
        # HTML5 exposes xlink/xml/xmlns attributes with their namespaces.
        if attribute.namespace && !(svg && node.name == "svg" && name == "xmlns" &&
            value == SVG_NAMESPACE)
          add_error("Namespaced attributes are unsupported: #{node.name}.#{name}")
          next
        end
        global = svg ? SVG_GLOBAL_ATTRIBUTES : HTML_GLOBAL_ATTRIBUTES
        specific = (svg ? SVG_ATTRIBUTES : HTML_ATTRIBUTES).fetch(node.name, [])
        aria = name.match?(/\Aaria-[a-z-]+\z/)
        unless global.include?(name) || specific.include?(name) || aria
          add_error("Unsupported attribute: #{node.name}.#{name}")
          next
        end
        case name
        when "id"
          add_error("Duplicate id") if @ids.key?(value)
          @ids[value] = node
        when "style"
          validate_css(value, node)
        when "href"
          reference(value, node, :use)
        when "xmlns"
          add_error("Only the SVG namespace is supported") unless value == SVG_NAMESPACE
        else
          # SVG presentation attributes use CSS syntax too. Geometry and
          # transform attributes cannot fetch resources.
          if svg && ((SVG_GLOBAL_ATTRIBUTES - %w[id class]).include?(name) ||
              %w[stop-color stop-opacity].include?(name))
            validate_css(value, node)
          end
        end
      end
      if node.name == "style"
        add_error("Only CSS styles are supported") if node["type"] && node["type"].downcase != "text/css"
        validate_css(node.content, node)
      elsif !svg && node.name == "meta"
        validate_meta(node)
      elsif !svg && node.name == "img"
        validate_image(node["src"])
      elsif svg && node.name == "use" && !node["href"]
        add_error("SVG use requires a local href")
      end
    end

    def validate_meta(node)
      if node["charset"]
        add_error("Only UTF-8 charset metadata is supported") unless
          node["charset"].downcase == "utf-8" && !node["name"] && !node["content"]
      elsif !%w[description viewport].include?(node["name"]) || !node["content"]
        add_error("Only charset, description and viewport metadata are supported")
      end
    end

    def validate_css(css, node)
      @css_bytes += css.bytesize
      return add_error("CSS exceeds the #{MAX_CSS_BYTES} byte limit") if @css_bytes > MAX_CSS_BYTES
      # Stream lexical tokens: Crass's stylesheet parser can discard malformed
      # constructs, which is unsuitable for auditing an unchanged input string.
      tokenizer = Crass::Tokenizer.new(css)
      while (token = tokenizer.consume)
        @css_tokens += 1
        return add_error("CSS exceeds the token limit") if @css_tokens > MAX_CSS_TOKENS
        value = token[:value].to_s.downcase
        case token[:node]
        when :at_keyword
          add_error("Unsupported CSS at-rule: @#{value}") unless CSS_AT_RULES.include?(value)
        when :url
          reference(token[:value], node, :paint)
        when :function
          if value == "url"
            string = next_css_token(tokenizer)
            closing = next_css_token(tokenizer)
            if string && string[:node] == :string && closing && closing[:node] == :")"
              reference(string[:value], node, :paint)
            else
              add_error("CSS url() must be a literal local fragment")
            end
          elsif !CSS_FUNCTIONS.include?(value)
            add_error("Unsupported CSS function: #{value}")
          end
        when :bad_url, :bad_string
          add_error("Malformed CSS resource or string")
        end
        return if @errors.length >= MAX_ERRORS
      end
    end

    def next_css_token(tokenizer)
      while (token = tokenizer.consume)
        @css_tokens += 1
        return token unless token[:node] == :whitespace
      end
      nil
    end

    def reference(value, node, kind)
      unless value.match?(FRAGMENT)
        return add_error("Only literal local SVG fragment references are supported")
      end
      @references << [ value.delete_prefix("#"), node, kind ]
    end

    def validate_references
      @references.each do |id, source, kind|
        target = @ids[id]
        allowed = kind == :use ? SVG_USE_TARGETS : SVG_PAINT_TARGETS
        unless target && target.namespace&.href == SVG_NAMESPACE && allowed.include?(target.name)
          add_error("SVG fragment must target a supported #{kind} element: ##{id}")
          next
        end
        if kind == :use
          # Leaf geometry only: no nested use, external trees, or reference cycles.
          if target.element_children.any? || svg_root(source) != svg_root(target)
            add_error("SVG use must target leaf geometry in the same SVG")
          end
        end
        break if @errors.length >= MAX_ERRORS
      end
    end

    def svg_root(node)
      node.ancestors.find { |ancestor| ancestor.name == "svg" && ancestor.namespace&.href == SVG_NAMESPACE }
    end

    def validate_image(src)
      @images += 1
      return add_error("Too many images") if @images > MAX_IMAGES
      match = src&.match(/\Adata:image\/(png|jpeg|webp);base64,([A-Za-z0-9+\/]*={0,2})\z/)
      return add_error("Images require base64 data PNG, JPEG or WebP") unless match
      if match[2].bytesize > ((MAX_IMAGE_BYTES + 2) / 3) * 4
        return add_error("Image exceeds the #{MAX_IMAGE_BYTES} byte limit")
      end
      data = Base64.strict_decode64(match[2])
      @image_bytes += data.bytesize
      if data.bytesize > MAX_IMAGE_BYTES || @image_bytes > MAX_IMAGE_TOTAL_BYTES
        return add_error("Image byte budget exceeded")
      end
      signature, loader = IMAGE_TYPES.fetch(match[1])
      unless data.start_with?(signature) && (match[1] != "webp" || data.byteslice(8, 4) == "WEBP")
        return add_error("Image MIME type does not match its bytes")
      end
      # libpng can ignore APNG's extra frames, so header metadata from Vips
      # alone is insufficient. Inspect chunk boundaries, not substring matches.
      if animated_raster?(data, match[1])
        return add_error("Animated or multipage images are unsupported")
      end
      # Call only the declared raster loader, never Vips's format autodetection
      # (which would also admit SVG/PDF and other delegate formats).
      image = Vips::Image.public_send(loader, data, access: :sequential, fail_on: :warning)
      pixels = image.width * image.height
      @image_pixels += pixels
      unless image.width.positive? && image.height.positive? &&
          image.width <= MAX_IMAGE_DIMENSION && image.height <= MAX_IMAGE_DIMENSION &&
          pixels <= MAX_IMAGE_PIXELS && @image_pixels <= MAX_TOTAL_IMAGE_PIXELS
        return add_error("Image dimensions or pixel budget exceeded")
      end
      # Reject animations/multipage rasters; bounds apply to the decoded image.
      if image.get_fields.include?("n-pages") && image.get("n-pages") > 1
        return add_error("Animated or multipage images are unsupported")
      end
      image.avg # Force the complete decode, not just header inspection.
    rescue ArgumentError, Vips::Error
      add_error("Image data could not be decoded completely")
    end

    def animated_raster?(data, type)
      if type == "png"
        offset = 8
        while offset + 12 <= data.bytesize
          length = data.byteslice(offset, 4).unpack1("N")
          return true if data.byteslice(offset + 4, 4) == "acTL"
          offset += length + 12
        end
      elsif type == "webp"
        offset = 12
        while offset + 8 <= data.bytesize
          name = data.byteslice(offset, 4)
          length = data.byteslice(offset + 4, 4).unpack1("V")
          return true if %w[ANIM ANMF].include?(name)
          offset += length + 8 + (length % 2)
        end
      end
      false
    end

    def add_error(message)
      @errors << message[0, 240] if @errors.length < MAX_ERRORS
    end

    def fail_with(message)
      raise Invalid, [ message ]
    end

  end
end
