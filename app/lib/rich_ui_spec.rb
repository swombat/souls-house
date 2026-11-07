# A deliberately static subset of json-render. This is the server trust boundary,
# not merely a prompt schema: unknown fields and all dynamic props are refused.
class RichUiSpec

  class Invalid < StandardError; end

  MAX_BYTES = 256 * 1024
  MAX_ELEMENTS = 50
  MAX_DEPTH = 10
  ID = /\A[a-zA-Z0-9_-]{1,64}\z/
  RESERVED_IDS = %w[__proto__ prototype constructor].freeze
  PROPS = {
    "Stack" => [], "Card" => %w[title], "Text" => %w[text],
    "Metric" => %w[label value detail], "Table" => %w[title columns rows],
    "Chart" => %w[title kind labels series]
  }.freeze

  def initialize(spec)
    @spec = spec
  end

  def validate!
    object!(@spec, "rich_ui", %w[version root elements fallback], %w[version root elements])
    text!(@spec["fallback"], "fallback", 3500) if @spec.key?("fallback")
    fail!("version must be 1") unless @spec["version"].is_a?(Integer) && @spec["version"] == 1
    fail!("must be at most #{MAX_BYTES} bytes") if JSON.generate(@spec).bytesize > MAX_BYTES
    id!(@spec["root"], "root")
    @elements = @spec["elements"]
    fail!("elements must contain 1..#{MAX_ELEMENTS} elements") unless @elements.is_a?(Hash) && @elements.size.between?(1, MAX_ELEMENTS)
    @elements.each { |id, element| validate_element!(id, element) }
    seen = {}
    visit!(@spec["root"], seen, 1)
    fail!("elements must all be reachable from root") unless seen.size == @elements.size
    self
  rescue JSON::GeneratorError, JSON::NestingError
    fail!("must be finite, bounded JSON")
  end

  # Never expand the JSON into the wake prompt. Titles are escaped and shortened;
  # no table cell or arbitrary nested text is interpolated into this line.
  def summary
    validate!
    counts = @elements.values.map { |element| element["type"] }.tally
    descriptions = @elements.values.filter_map do |element|
      props = element["props"]
      title = props["title"] ? " #{props["title"].first(60).to_json}" : ""
      case element["type"]
      when "Table" then "table#{title}: #{props["columns"].size} cols × #{props["rows"].size} rows"
      when "Chart" then "chart #{props["kind"]}#{title}: #{props["series"].size} series × #{props["labels"].size} points"
      end
    end.first(5)
    descriptions << "#{counts["Metric"]} metrics" if counts["Metric"]
    descriptions << "#{@elements.size} elements"
    "[Rich UI: #{descriptions.join("; ")}; full data: soulshouse-share show CHAT_ID MESSAGE_ID]"
  rescue Invalid
    "[Rich UI unavailable; use the message's prose fallback]"
  end

  private

  def fail!(message)
    raise Invalid, "rich_ui #{message}"
  end

  def object!(value, path, allowed, required = [])
    fail!("#{path} must be an object") unless value.is_a?(Hash)
    fail!("#{path} has unsupported fields") unless (value.keys - allowed).empty?
    fail!("#{path} requires #{required.join(", ")}") unless (required - value.keys).empty?
  end

  def text!(value, path, max = 200)
    fail!("#{path} must be nonblank text of at most #{max} characters without NUL") unless
      value.is_a?(String) && value.strip.present? && value.length <= max && !value.include?("\0")
  end

  def id!(value, path)
    fail!("#{path} must be a safe ID of 1..64 characters") unless value.is_a?(String) && ID.match?(value) && !RESERVED_IDS.include?(value)
  end

  def array!(value, path, min, max)
    fail!("#{path} must be an array of #{min}..#{max} items") unless value.is_a?(Array) && value.size.between?(min, max)
  end

  def number!(value, path)
    fail!("#{path} must be a finite number; quote large exact integers") unless
      (value.is_a?(Integer) || value.is_a?(Float)) && value.finite? &&
        (value % 1 != 0 || value.abs <= 9_007_199_254_740_991)
  end

  def validate_element!(id, element)
    id!(id, "element ID")
    path = "elements.#{id}"
    object!(element, path, %w[type props children], %w[type props])
    type = element["type"]
    fail!("#{path}.type must be one of #{PROPS.keys.join(", ")}") unless PROPS.key?(type)
    props = element["props"]
    object!(props, "#{path}.props", PROPS.fetch(type))
    text!(props["title"], "#{path}.props.title") if props.key?("title")
    case type
    when "Text"
      text!(props["text"], "#{path}.props.text", 4000)
    when "Metric"
      text!(props["label"], "#{path}.props.label")
      text!(props["value"], "#{path}.props.value", 4000)
      text!(props["detail"], "#{path}.props.detail", 4000) if props.key?("detail")
    when "Table"
      validate_table!(props, path)
    when "Chart"
      validate_chart!(props, path)
    end
    children = element.fetch("children", [])
    array!(children, "#{path}.children", 0, MAX_ELEMENTS)
    fail!("#{path} cannot have children") if children.any? && !%w[Stack Card].include?(type)
    children.each { |child| id!(child, "#{path}.children") }
  end

  def validate_table!(props, path)
    columns = props["columns"]
    array!(columns, "#{path}.columns", 1, 20)
    columns.each { |column| text!(column, "#{path}.columns") }
    rows = props["rows"]
    array!(rows, "#{path}.rows", 0, 500)
    rows.each_with_index do |row, index|
      cell_path = "#{path}.rows[#{index}]"
      array!(row, cell_path, columns.size, columns.size)
      row.each do |cell|
        case cell
        when String
          fail!("#{cell_path} strings must be at most 4000 characters without NUL") if cell.length > 4000 || cell.include?("\0")
        when Integer, Float then number!(cell, cell_path)
        when NilClass, TrueClass, FalseClass then next
        else fail!("#{cell_path} cells must be string, number, boolean or null")
        end
      end
    end
  end

  def validate_chart!(props, path)
    fail!("#{path}.kind must be line or bar") unless %w[line bar].include?(props["kind"])
    labels = props["labels"]
    array!(labels, "#{path}.labels", 1, 200)
    labels.each { |label| text!(label, "#{path}.labels") }
    array!(props["series"], "#{path}.series", 1, 8)
    props["series"].each do |series|
      object!(series, "#{path}.series", %w[name values], %w[name values])
      text!(series["name"], "#{path}.series.name")
      array!(series["values"], "#{path}.series.values", labels.size, labels.size)
      series["values"].each { |value| number!(value, "#{path}.series.values") }
    end
  end

  def visit!(id, seen, depth)
    fail!("tree depth must be at most #{MAX_DEPTH}") if depth > MAX_DEPTH
    fail!("tree contains a cycle or shared child") if seen[id]
    element = @elements[id]
    fail!("tree references missing element #{id}") unless element
    seen[id] = true
    element.fetch("children", []).each { |child| visit!(child, seen, depth + 1) }
  end

end
