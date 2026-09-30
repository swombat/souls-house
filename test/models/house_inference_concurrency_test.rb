require 'test_helper'

class HouseInferenceConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  test 'competing accounts claim only one slot and competing calls only one reservation' do
    agents = [ agents(:research_assistant), agents(:other_account_agent) ]
    original_models = agents.map(&:model_id)
    agents.each { |agent| agent.update_columns(model_id: HouseInference::Offering::MODEL_ID) }
    user = users(:user_1)
    results = race(agents.map(&:id)) do |id|
      HouseInferenceGrant.assign!(Agent.find(id), user)
    rescue ActiveRecord::RecordInvalid
      :refused
    end
    assert_equal 1, results.count(:refused)
    grant = HouseInferenceGrant.find_by!(user: user)
    HouseInference::Offering.stub(:configured?, true) do
      results = race([ grant.id, grant.id ]) do |id|
        HouseInferenceGrant.find(id).reserve!(HouseInference::Offering.find(HouseInference::Offering::MODEL_ID), HouseInference::Offering::MODEL_ID)
      rescue HouseInference::Error
        :refused
      end
      assert_equal 1, results.count(:refused)
      assert_equal 1, grant.house_inference_calls.count
      assert_equal BigDecimal('0.75'), grant.spent
    end
  ensure
    if user
      grant = HouseInferenceGrant.find_by(user: user)
      HouseInferenceCall.where(house_inference_grant: grant).delete_all if grant
      grant&.destroy!
    end
    agents&.zip(original_models || [])&.each { |agent, model| agent.update_columns(model_id: model) }
  end

  private

  def race(items)
    ready, start = Queue.new, Queue.new
    workers = items.map do |item|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          yield item
        end
      end
    end
    items.size.times { ready.pop }
    items.size.times { start << true }
    workers.map(&:value)
  ensure
    workers&.each(&:join)
  end

end
