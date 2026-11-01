require "test_helper"

class DataModelPageTest < ActionDispatch::IntegrationTest

  test "the data model page opens on the first area without authentication" do
    get data_model_path
    assert_response :success
    assert_equal "data-model", inertia_component
    props = inertia_props["props"]
    assert_equal DataModel.areas.first.id, props["area"]["id"]
    assert_equal DataModel.areas.map(&:id), props["areas"].map { |area| area["id"] }
    assert_equal DataModel.schema_tables.size, props["table_count"]
    assert_equal DataModel::REPOSITORY_PATH, props["map_url"]
  end

  test "an area by id carries its tables, prose and diagram" do
    get data_model_path("billing")
    assert_response :success
    area = inertia_props["props"]["area"]
    assert_equal "Billing", area["title"]
    assert_match(/Stripe/, area["summary"])
    assert_includes area["tables"].map { |table| table["name"] }, "resident_subscriptions"
    assert area["diagram"].start_with?("erDiagram")
    subscription = area["tables"].find { |table| table["name"] == "resident_subscriptions" }
    assert_includes subscription["columns"].map { |column| column["name"] }, "stripe_subscription_id"
    assert_equal "residents", subscription["references"].find { |r| r["column"] == "agent_id" }["area"]["id"]
  end

  test "an unknown area is not found" do
    get data_model_path("kitchen")
    assert_response :not_found
  end

end
