require 'test_helper'

class HouseInference::OfferingTest < ActiveSupport::TestCase

  test 'new house residents default to Haiku, listed first' do
    assert_equal 'house/claude-haiku-5.5', HouseInference::Offering::DEFAULT_MODEL_ID
    assert_equal [ 'house/claude-haiku-5.5', 'house/deepseek-v4.1-flash' ], HouseInference::Offering.models.pluck(:model_id)
    assert HouseInference::Offering.models.all? { |model| model[:group] == 'On the house' }
  end

  test 'each route is pinned to one provider' do
    haiku = HouseInference::Offering.find(HouseInference::Offering::HAIKU_MODEL_ID)
    assert_equal 'anthropic/claude-haiku-5.5', haiku[:upstream_model]
    assert_equal 'anthropic', haiku[:provider]
    deepseek = HouseInference::Offering.find(HouseInference::Offering::DEEPSEEK_MODEL_ID)
    assert_equal 'deepseek/deepseek-v4.1-flash', deepseek[:upstream_model]
    assert_equal 'fireworks/us', deepseek[:provider]
  end

  test 'a full context and maximum output at the price caps fits inside the reservation' do
    HouseInference::Offering::OFFERINGS.each do |id, offering|
      worst = (offering[:context_tokens] * offering[:max_price][:prompt] +
        offering[:max_output_tokens] * offering[:max_price][:completion]) / 1_000_000.0
      assert_operator worst, :<, offering[:reservation_usd], id
      assert_operator offering[:reservation_usd], :<, 1, id
    end
  end

  test 'Haiku price caps admit its long-context tier instead of refusing long conversations' do
    caps = HouseInference::Offering.find(HouseInference::Offering::HAIKU_MODEL_ID)[:max_price]
    # OpenRouter on 2026-10-08: prompts over 100k tokens cost $0.50/M in, $2.50/M out.
    assert_operator caps[:prompt], :>=, 0.5
    assert_operator caps[:completion], :>=, 2.5
  end

end
