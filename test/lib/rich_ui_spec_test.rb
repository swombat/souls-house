require "test_helper"

class RichUiSpecTest < ActiveSupport::TestCase

  def table(props = {})
    {
      "version" => 1, "root" => "main", "elements" => {
        "main" => { "type" => "Table", "props" => {
          "columns" => [ "Name", "Value" ], "rows" => [ [ "one", 1 ], [ nil, false ] ]
        }.merge(props) }
      }
    }
  end

  def assert_invalid(spec, pattern = /rich_ui/)
    assert_match pattern, assert_raises(RichUiSpec::Invalid) { RichUiSpec.new(spec).validate! }.message
  end

  test "accepts static typed table and summarizes dimensions not data" do
    spec = table("title" => "Results\nquoted")
    assert RichUiSpec.new(spec).validate!
    summary = RichUiSpec.new(spec).summary
    assert_includes summary, "2 cols × 2 rows"
    assert_includes summary, 'Results\nquoted'
    assert_not_includes summary, "\n"
    assert_not_includes summary, '"one"'
    assert_operator summary.bytesize, :<, 400
  end

  test "rejects unsupported versions shapes props and dynamic features" do
    [ nil, [], "text", 1, {} ].each { |value| assert_invalid(value) }
    [ 2, "1", 1.0, true ].each { |version| assert_invalid(table.merge("version" => version)) }
    %w[state actions computed repeat].each { |key| assert_invalid(table.merge(key => {})) }
    %w[on watch visible repeat].each do |key|
      spec = table
      spec["elements"]["main"][key] = {}
      assert_invalid(spec)
    end
    assert_invalid(table("columns" => [ { "$state" => "/secret" } ]))
    assert_invalid(table("rows" => [ [ "x", { "$computed" => "fetch" } ] ]))
    assert_invalid(table("url" => "https://example.org"))
    spec = table
    spec["elements"]["main"]["type"] = "Script"
    assert_invalid(spec)
  end

  test "bounds table rows columns widths strings and bytes" do
    assert_invalid(table("columns" => []))
    assert_invalid(table("columns" => Array.new(21, "X")))
    assert_invalid(table("rows" => Array.new(501) { [ "x", 1 ] }))
    assert_invalid(table("rows" => [ [ "short" ] ]))
    assert_invalid(table("rows" => [ [ "x", "a" * 4001 ] ]))
    assert_invalid(table("title" => "a" * 201))
    assert_invalid(table("rows" => [ [ "nul\0", 1 ] ]))
    assert_invalid(table("rows" => [ [ "unsafe integer", 9_007_199_254_740_992 ] ]))
    assert_invalid(table("rows" => Array.new(100) { [ "x" * 4000, 1 ] }), /bytes/)
  end

  test "validates chart values and lengths and rejects nonfinite numbers" do
    chart = table
    chart["elements"]["main"] = { "type" => "Chart", "props" => {
      "kind" => "line", "labels" => [ "one", "two" ],
      "series" => [ { "name" => "test", "values" => [ -1, 0.5 ] } ]
    } }
    assert RichUiSpec.new(chart).validate!
    assert_includes RichUiSpec.new(chart).summary, "1 series × 2 points"
    [ "nan", nil, true, {}, Float::INFINITY, Float::NAN ].each do |value|
      bad = chart.deep_dup
      bad["elements"]["main"]["props"]["series"][0]["values"][0] = value
      assert_invalid(bad)
    end
    bad = chart.deep_dup
    bad["elements"]["main"]["props"]["series"][0]["values"] = [ 1 ]
    assert_invalid(bad)
  end

  test "requires a bounded rooted tree with unique reachable children and safe IDs" do
    spec = table
    spec["elements"]["root"] = { "type" => "Stack", "props" => {}, "children" => [ "main" ] }
    spec["root"] = "root"
    assert RichUiSpec.new(spec).validate!
    [
      [ "main", "main" ], [ "root" ], [ "missing" ]
    ].each do |children|
      bad = spec.deep_dup
      bad["elements"]["root"]["children"] = children
      assert_invalid(bad)
    end
    assert_invalid(spec.merge("root" => "main"), /reachable/)
    bad = spec.deep_dup
    bad["elements"]["main"]["children"] = [ "root" ]
    assert_invalid(bad, /cannot have children/)
    %w[__proto__ prototype constructor a.b].each { |id| assert_invalid(spec.merge("root" => id)) }
    nested = { "version" => 1, "root" => "n0", "elements" => {} }
    11.times do |index|
      nested["elements"]["n#{index}"] = { "type" => "Stack", "props" => {}, "children" => index < 10 ? [ "n#{index + 1}" ] : [] }
    end
    assert_invalid(nested, /depth/)
    assert_invalid(table.merge("elements" => (1..51).to_h { |i| [ "n#{i}", {} ] }), /elements/)
  end

  test "accepts cards text metrics but requires string metric values" do
    spec = { "version" => 1, "root" => "card", "elements" => {
      "card" => { "type" => "Card", "props" => { "title" => "Report" }, "children" => [ "text", "metric" ] },
      "text" => { "type" => "Text", "props" => { "text" => "<script>alert('just text')</script>" } },
      "metric" => { "type" => "Metric", "props" => { "label" => "Count", "value" => "42", "detail" => "Observed" } }
    } }
    assert RichUiSpec.new(spec).validate!
    assert_includes RichUiSpec.new(spec).summary, "1 metrics"
    spec["elements"]["metric"]["props"]["value"] = 42
    assert_invalid(spec)
  end

end
