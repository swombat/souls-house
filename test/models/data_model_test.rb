require "test_helper"

class DataModelTest < ActiveSupport::TestCase

  test "every table in the schema belongs to an area" do
    assert_empty DataModel.unmapped_tables,
      "These tables exist in the schema but config/data_model.yml does not place them in an area. " \
      "Add each to the area it belongs to (a table may be in more than one) so /data-model stays complete."
  end

  test "every table the map names exists in the schema" do
    assert_empty DataModel.unknown_tables,
      "config/data_model.yml names tables the schema no longer has; remove them from their areas."
  end

  test "areas have unique ids, titles, prose and at least one table" do
    areas = DataModel.areas
    assert_equal areas.map(&:id).uniq, areas.map(&:id)
    areas.each do |area|
      assert_match(/\A[a-z-]+\z/, area.id)
      assert area.title.present?, "#{area.id} has no title"
      assert area.summary.length > 80, "#{area.id} has no real summary"
      assert area.table_names.any?, "#{area.id} has no tables"
      assert_equal area.table_names.uniq, area.table_names, "#{area.id} lists a table twice"
    end
  end

  test "area json carries every table with its columns and a diagram naming each" do
    DataModel.areas.each do |area|
      json = DataModel.area_json(area)
      assert_equal area.table_names, json[:tables].map { |table| table[:name] }
      json[:tables].each do |table|
        assert table[:columns].any?, "#{table[:name]} has no columns"
        assert table[:columns].any? { |column| column[:primary_key] }, "#{table[:name]} has no primary key"
        assert_includes table[:areas], area.id
      end
      assert json[:diagram].start_with?("erDiagram\n")
      area.table_names.each { |name| assert_includes json[:diagram], "  #{name} {" }
    end
  end

  test "a reference inside the area has no area link and one outside names the other area" do
    json = DataModel.area_json(DataModel.find("conversations"))
    messages = json[:tables].find { |table| table[:name] == "messages" }
    chat = messages[:references].find { |reference| reference[:column] == "chat_id" }
    assert_equal "chats", chat[:table]
    assert_nil chat[:area]
    user = messages[:references].find { |reference| reference[:column] == "user_id" }
    assert_equal "users", user[:table]
    assert_equal({ id: "accounts", title: "Accounts and people" }, user[:area])
    assert_includes json[:diagram], "  messages }o--|| chats : chat_id"
  end

  test "a table in two areas says so and the first area is used for links" do
    json = DataModel.area_json(DataModel.find("billing"))
    entitlement = json[:tables].find { |table| table[:name] == "resident_entitlements" }
    agent = entitlement[:references].find { |reference| reference[:column] == "agent_id" }
    assert_equal "residents", agent[:area][:id]
    assert_equal %w[residents hosting], DataModel.area_json(DataModel.find("hosting"))
      .dig(:tables).find { |table| table[:name] == "agent_backup_snapshots" }[:areas]
  end

  test "find returns nil for an unknown area" do
    assert_nil DataModel.find("kitchen")
    assert_equal "field", DataModel.find(:field).id
  end

end
