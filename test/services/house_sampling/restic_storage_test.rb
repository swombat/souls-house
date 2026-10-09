require "test_helper"

class HouseSampling::ResticStorageTest < ActiveSupport::TestCase

  test "sums every object under the resident's repository prefix, across pages" do
    agent = agents(:research_assistant)
    agent.update_columns(uuid: SecureRandom.uuid) if agent.uuid.blank?
    object = Struct.new(:size)
    page = Struct.new(:contents)
    seen = nil
    client = Object.new
    client.define_singleton_method(:list_objects_v2) do |bucket:, prefix:|
      seen = [ bucket, prefix ]
      [ page.new([ object.new(100), object.new(50) ]), page.new([ object.new(7) ]) ]
    end
    Backup::AgentRestic.stub(:bucket, "house-backups") do
      result = HouseSampling::ResticStorage.new(client:).call(agent)
      assert_equal({ "bytes" => 157, "objects" => 3 }, result)
      assert_equal [ "house-backups", "agents/#{agent.uuid}/" ], seen
    end
  end

end
