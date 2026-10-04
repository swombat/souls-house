require "test_helper"
require_relative "../../db/migrate/20261004150000_create_visual_tags"

class VisualTagTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  setup do
    @account = accounts(:personal_account)
    @tag = @account.visual_tags.create!(label: "Building", icon: "Wrench", colour: "blue")
    @chat = @account.chats.create!(title: "Unchanged", model_id: "openrouter/auto", visual_tag: @tag)
  end

  test "validates a bounded plain label and allowlisted presentation keys" do
    @tag.assign_attributes(label: "   ", icon: "<svg>", colour: "var(--custom)")
    assert_not @tag.valid?
    assert @tag.errors[:label].any?
    assert @tag.errors[:icon].any?
    assert @tag.errors[:colour].any?

    @tag.assign_attributes(label: "x" * 81, icon: "Wrench", colour: "blue")
    assert_not @tag.valid?
    @tag.label = "Bad\0label"
    assert_not @tag.valid?
    @tag.update!(label: "  New label  ")
    assert_equal "New label", @tag.label
  end

  test "public representation is stable and contains only presentation fields" do
    id = @tag.to_param
    @tag.update!(label: "Updated")
    assert_equal id, @tag.reload.to_param
    assert_equal %w[colour icon id label], @tag.as_json.keys.sort
    assert_equal @tag, VisualTag.resolve_for(@account, id)
    assert_nil VisualTag.resolve_for(@account, nil)
    [ @tag.id, @tag.id.to_s, "", [], {}, "unknown" ].each do |invalid|
      assert_raises(ActiveRecord::RecordNotFound) { VisualTag.resolve_for(@account, invalid) }
    end
  end

  test "the full generated Phosphor catalog is accepted without accepting SVG or arbitrary keys" do
    catalog = JSON.parse(Rails.root.join("config/visual_tag_icons.json").read)
    assert_equal catalog, VisualTag::ICON_OPTIONS
    assert_equal catalog.sort.uniq, catalog
    assert_operator catalog.length, :>, 1500

    catalog.each do |icon|
      @tag.icon = icon
      assert @tag.valid?, "#{icon} should be selectable"
    end
    @tag.update!(icon: "Yarn")
    assert_equal "Yarn", @tag.reload.as_json["icon"]

    [ nil, "", "IconContext", "UnknownIcon", "yarn", "Yarn#duotone",
      "__proto__", "constructor", "<svg><script/></svg>", { d: "M0,0" } ].each do |icon|
      @tag.icon = icon
      assert_not @tag.valid?, "#{icon.inspect} must not be selectable"
      assert @tag.errors[:icon].any?
    end
  end

  test "tags cannot move accounts and chats cannot select foreign tags" do
    other = accounts(:other)
    assert_not @tag.update(account: other)
    @tag.reload
    assert_not @chat.update(account: other)
    assert @chat.errors[:visual_tag].any?

    foreign = other.visual_tags.create!(label: "Care", icon: "Heart", colour: "rose")
    assert_not @chat.update(account: @account, visual_tag: foreign)
    # Even validation-skipping persistence is constrained by ownership.
    assert_raises(ActiveRecord::InvalidForeignKey) do
      Chat.transaction(requires_new: true) { @chat.update_columns(visual_tag_id: foreign.id) }
    end
  end

  test "new accounts receive all nine defaults and no conversations are selected" do
    account = Account.create!(name: "New palette", account_type: :team)
    assert_equal VisualTag::DEFAULTS, account.visual_tags.palette_order.pluck(:label, :icon, :colour)
    assert_empty account.chats
    account.visual_tags.first.destroy!
    account.update!(name: "Still edited")
    assert_equal 8, account.visual_tags.count
  end

  test "migration seeds existing accounts without selecting existing chats" do
    @chat.update!(visual_tag: nil)
    @tag.destroy!
    assert_empty @account.visual_tags.reload

    # Exercise the real migration's backfill against fixture accounts.
    ActiveRecord::Migration.suppress_messages { CreateVisualTags.new.seed_existing_accounts }

    assert_equal VisualTag::DEFAULTS, @account.visual_tags.palette_order.pluck(:label, :icon, :colour)
    assert_nil @chat.reload.visual_tag
    assert_equal "Unchanged", @chat.title
  end

  test "palette edits invalidate cached room and sidebar JSON and broadcast normal list refreshes" do
    @chat.cached_json
    @chat.cached_sidebar_json
    account_channel = "Account:#{@account.to_param}"
    chat_channel = "Chat:#{@chat.to_param}"
    assert_broadcasts(account_channel, 1) do
      assert_broadcasts(chat_channel, 0) { @tag.update!(label: "Revised", colour: "green") }
    end
    assert_equal "Revised", @chat.reload.cached_json["visual_tag"]["label"]
    assert_equal "green", @chat.cached_sidebar_json["visual_tag"]["colour"]
    assert_equal "Unchanged", @chat.title
  end

  test "deleting a tag clears kept archived and discarded chats and refreshes caches" do
    archived = @account.chats.create!(title: "Archived", model_id: "openrouter/auto", visual_tag: @tag)
    archived.archive!
    discarded = @account.chats.create!(title: "Deleted", model_id: "openrouter/auto", visual_tag: @tag)
    discarded.discard!
    @chat.cached_sidebar_json

    assert_no_difference "Chat.count" do
      assert_broadcasts("Account:#{@account.to_param}", 4) { @tag.destroy! }
    end
    [ @chat, archived, discarded ].each { |chat| assert_nil chat.reload.visual_tag_id }
    assert_nil @chat.cached_sidebar_json["visual_tag"]
    assert_equal "Unchanged", @chat.title
  end

  test "selected visual tag is serialized in room sidebar and live list projection" do
    expected = @tag.as_json
    assert_equal expected, @chat.as_json["visual_tag"]
    assert_equal expected, @chat.cached_sidebar_json["visual_tag"]
    assert_equal expected, Chat.sidebar_json_for([ @chat ]).first["visual_tag"]
    assert_not @chat.as_json.key?("visual_tag_id")
    @chat.update!(visual_tag: nil)
    assert_nil @chat.as_json["visual_tag"]
  end

  test "account destruction removes its palette after its chats" do
    account = Account.create!(name: "Disposable palette", account_type: :team)
    tag = account.visual_tags.first
    account.chats.create!(title: "Synthetic room", model_id: "openrouter/auto", visual_tag: tag)
    account.destroy!
    assert_not VisualTag.exists?(tag.id)
  end

end
