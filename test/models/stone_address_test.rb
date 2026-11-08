require "test_helper"

class StoneAddressTest < ActiveSupport::TestCase

  setup do
    @chat = agents(:research_assistant).account.chats.create!(title: "Stone addresses", model_id: "openrouter/auto")
    @stone = Stone.create!(chat: @chat)
  end

  test "the bounded vocabulary has 256 distinct sorted lowercase words" do
    words = StoneAddress::WORDS
    assert_equal 256, words.size
    assert_equal words, words.uniq.sort
    assert words.all? { |word| word.match?(/\A[a-z]+\z/) }
    assert_equal 16_777_216, StoneAddress::CAPACITY
  end

  test "random names draw three times with replacement" do
    SecureRandom.stub(:random_number, 0) do
      assert_equal "abyss-abyss-abyss", StoneAddress.random_name
    end
  end

  test "reserving an address is idempotent and uses the vocabulary" do
    address = StoneAddress.reserve!(stone: @stone)
    assert_equal @stone, address.stone
    assert_equal 3, address.name.split("-").size
    assert address.name.split("-").all? { |word| StoneAddress::WORDS.include?(word) }
    assert_no_difference "StoneAddress.count" do
      assert_equal address, StoneAddress.reserve!(stone: @stone)
    end
  end

  test "allocation requires a persisted stone" do
    [ nil, Stone.new ].each do |stone|
      assert_raises(ArgumentError) { StoneAddress.reserve!(stone: stone) }
    end
  end

  test "a real unique name collision rolls back its savepoint and retries inside an outer transaction" do
    StoneAddress.create!(name: "abyss-abyss-abyss")
    candidates = [ "abyss-abyss-abyss", "stone-stone-stone" ]
    StoneAddress.transaction do
      StoneAddress.stub(:random_name, -> { candidates.shift }) do
        assert_equal "stone-stone-stone", StoneAddress.reserve!(stone: @stone).name
      end
      assert_equal 2, StoneAddress.count
      # A later write also succeeds: the unique violation did not poison us.
      @stone.update!(withdrawn_at: Time.current)
    end
  end

  test "repeated collisions raise a useful bounded exhaustion error without poisoning the transaction" do
    StoneAddress.create!(name: "abyss-abyss-abyss")
    attempts = 0
    StoneAddress.stub(:random_name, -> { attempts += 1; "abyss-abyss-abyss" }) do
      error = assert_raises(StoneAddress::Exhausted) { StoneAddress.reserve!(stone: @stone) }
      assert_match(/#{StoneAddress::MAX_ATTEMPTS} attempts/, error.message)
      assert_match(/administrator/, error.message)
    end
    assert_equal StoneAddress::MAX_ATTEMPTS, attempts
    assert_nil StoneAddress.find_by(stone_id: @stone.id)
    assert_equal 1, StoneAddress.count
  end

  test "database uniqueness enforces one address per stone" do
    StoneAddress.reserve!(stone: @stone)
    assert_raises(ActiveRecord::RecordNotUnique) do
      StoneAddress.transaction(requires_new: true) do
        StoneAddress.create!(stone: @stone, name: "moon-moon-moon")
      end
    end
  end

  test "names cannot change and reservations cannot be destroyed or reassigned" do
    address = StoneAddress.reserve!(stone: @stone)
    name = address.name
    assert_not address.update(name: "moon-moon-moon")
    assert_equal name, address.reload.name
    assert_not address.destroy
    assert StoneAddress.exists?(address.id)
    other = Stone.create!(chat: @stone.chat)
    assert_not address.update(stone: other)
  end

  test "withdrawal and physical deletion keep the original name reserved forever" do
    address = StoneAddress.reserve!(stone: @stone)
    name = address.name
    @stone.withdraw!
    assert_equal @stone.id, address.reload.stone_id
    @stone.destroy!
    assert_nil address.reload.stone_id
    assert_equal name, address.name
    assert_not address.update(stone: Stone.create!(chat: @chat))
    assert_raises(ActiveRecord::RecordNotUnique) do
      StoneAddress.transaction(requires_new: true) { StoneAddress.create!(name: name) }
    end
  end

  test "direct physical stone deletion nullifies rather than cascades the reservation" do
    address = StoneAddress.reserve!(stone: @stone)
    @stone.delete
    assert_nil address.reload.stone_id
  end

end
