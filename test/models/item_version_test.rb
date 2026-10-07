require "test_helper"

class ItemVersionTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @whiteboard = @account.whiteboards.create!(name: "Notes", content: "one")
  end

  test "changing the text keeps the text it replaced" do
    @whiteboard.update!(content: "two")
    @whiteboard.update!(content: "three")

    assert_equal %w[two one], @whiteboard.past_versions.map { |v| v.reify.content }
    first = @whiteboard.revision - 2
    assert_equal [ first + 1, first ], @whiteboard.past_versions.map { |v| v.reify.revision }
  end

  test "renaming keeps a version, bookkeeping alone does not" do
    assert_difference -> { @whiteboard.past_versions.count }, 1 do
      @whiteboard.update!(name: "Renamed")
    end

    assert_no_difference -> { @whiteboard.versions.count } do
      @whiteboard.touch
      @whiteboard.update!(content: @whiteboard.content)
    end
  end

  test "deleting and restoring are named as such" do
    @whiteboard.soft_delete!
    @whiteboard.restore!

    assert_equal %w[restored deleted], @whiteboard.past_versions.map { |v| NoteVersions.replaced_event(v) }
  end

  test "whodunnit names the kind of editor and resolves back to it" do
    user = users(:user_1)
    agent = agents(:research_assistant)

    assert_equal "User:#{user.id}", ItemVersion.whodunnit_for(user)
    assert_equal "Agent:#{agent.id}", ItemVersion.whodunnit_for(agent)
    assert_nil ItemVersion.whodunnit_for(nil)

    PaperTrail.request(whodunnit: ItemVersion.whodunnit_for(agent)) do
      @whiteboard.update!(content: "by a resident")
    end
    assert_equal agent, @whiteboard.versions.last.changed_by
  end

  test "an unknown or malformed whodunnit resolves to nobody" do
    @whiteboard.update!(content: "two")
    version = @whiteboard.versions.last

    [ nil, "", "Account:1", "User:abc", "Kernel:1" ].each do |value|
      version.whodunnit = value
      assert_nil version.changed_by, value.inspect
    end
  end

  test "version ids are obfuscated" do
    @whiteboard.update!(content: "two")
    version = @whiteboard.past_versions.first

    assert_no_match(/\A\d+\z/, version.to_param)
    assert_equal version, @whiteboard.past_versions.find(version.to_param)
  end

end
