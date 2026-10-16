require "test_helper"

class RoomNavigationTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  setup do
    @account = accounts(:personal_account)
    @stream = "RoomNavigation:#{@account.to_param}"
    @other_stream = "RoomNavigation:#{accounts(:existing_user_account).to_param}"
  end

  test "create rename and destroy each commit one content-free navigation marker" do
    room = nil
    assert_navigation_marker { room = @account.rooms.create!(name: "Life") }
    assert_navigation_marker { room.update!(name: "Home") }
    assert_navigation_marker { room.destroy! }
  end

  test "failed validation and rolled back lifecycle changes do not invalidate navigation" do
    room = @account.rooms.create!(name: "Life")
    assert_no_broadcasts(@stream) { assert_not room.update(name: "Main") }

    assert_no_broadcasts(@stream) do
      Room.transaction do
        @account.rooms.create!(name: "Work")
        room.update!(name: "Home")
        room.destroy!
        raise ActiveRecord::Rollback
      end
    end
    assert_equal "Life", room.reload.name
    assert_not @account.rooms.exists?(name: "Work")
  end

  test "reordering commits exactly one marker and no-ops at either end emit none" do
    first = @account.rooms.create!(name: "First")
    second = @account.rooms.create!(name: "Second")
    third = @account.rooms.create!(name: "Third")
    assert_no_broadcasts(@stream) { first.move!(-1) }
    assert_no_broadcasts(@stream) { third.move!(1) }
    assert_navigation_marker { second.move!(-1) }
    assert_equal [ second, first, third ], @account.rooms.reload.to_a
    assert_navigation_marker { second.move!(1) }
    assert_equal [ first, second, third ], @account.rooms.reload.to_a
  end

  test "reordering waits for outer commit and an outer rollback emits nothing" do
    first = @account.rooms.create!(name: "First")
    second = @account.rooms.create!(name: "Second")

    assert_no_broadcasts(@stream) do
      Room.transaction do
        second.move!(-1)
        raise ActiveRecord::Rollback
      end
    end
    assert_equal [ first, second ], @account.rooms.reload.to_a

    assert_navigation_marker do
      Room.transaction do
        assert_no_broadcasts(@stream) { second.move!(-1) }
      end
    end
    assert_equal [ second, first ], @account.rooms.reload.to_a
  end

  test "chat traffic does not invalidate room navigation" do
    assert_no_broadcasts(@stream) do
      chat = @account.chats.create!(title: "Quiet navigation", model_id: "openrouter/auto")
      chat.messages.create!(role: "assistant", content: "A reply")
      chat.update!(title: "Still quiet")
    end
  end

  private

  def assert_navigation_marker(&block)
    assert_no_broadcasts(@other_stream) do
      messages = capture_broadcasts(@stream, &block)
      assert_equal [ { "action" => "refresh" } ], messages
    end
  end

end
