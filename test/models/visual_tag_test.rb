require "test_helper"
require "active_record/testing/query_assertions"
require_relative "../../db/migrate/20261004150000_create_visual_tags"
require_relative "../../db/migrate/20261008060000_add_pinned_to_visual_tags"

class VisualTagTest < ActiveSupport::TestCase

  include ActionCable::TestHelper
  include ActiveRecord::Assertions::QueryAssertions

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
    assert_equal %w[colour icon id label pinned], @tag.as_json.keys.sort
    assert_equal @tag, VisualTag.resolve_for(@account, id)
    assert_nil VisualTag.resolve_for(@account, nil)
    [ @tag.id, @tag.id.to_s, "", [], {}, "unknown" ].each do |invalid|
      assert_raises(ActiveRecord::RecordNotFound) { VisualTag.resolve_for(@account, invalid) }
    end
  end

  test "browser palette ranks kept account conversations then alphabetical labels including unused tags" do
    alpha = @account.visual_tags.create!(label: "alpha", icon: "Heart", colour: "rose")
    popular = @account.visual_tags.create!(label: "Zulu", icon: "Compass", colour: "green")
    @account.visual_tags.create!(label: "zebra", icon: "Heart", colour: "rose")
    @account.visual_tags.create!(label: "Empty", icon: "Heart", colour: "rose")
    @account.chats.create!(title: "Alpha", model_id: "openrouter/auto", visual_tag: alpha)
    @account.chats.create!(title: "Popular", model_id: "openrouter/auto", visual_tag: popular)
    archived = @account.chats.create!(title: "Archived", model_id: "openrouter/auto", visual_tag: popular)
    archived.archive!
    3.times do
      @account.chats.create!(title: "Deleted", model_id: "openrouter/auto", visual_tag: @tag).discard!
    end
    foreign = accounts(:other).visual_tags.create!(label: "Foreign", icon: "Heart", colour: "rose")
    accounts(:other).chats.create!(title: "Foreign", model_id: "openrouter/auto", visual_tag: foreign)

    palette = VisualTag.palette_with_usage_for(@account)
    assert_equal %w[Zulu alpha Building Empty zebra], palette.pluck("label")
    assert_equal [ 2, 1, 1, 0, 0 ], palette.pluck("conversation_count")
    assert_equal %w[colour conversation_count icon id label pinned], palette.first.keys.sort
    assert_equal %w[colour icon id label pinned], popular.as_json.keys.sort
    assert_equal @tag.as_json, @chat.as_json["visual_tag"]
  end

  test "browser palette reflects selections clears discards and restores without cached counts" do
    other = @account.visual_tags.create!(label: "Other", icon: "Heart", colour: "rose")
    @chat.update!(visual_tag: other)
    palette = VisualTag.palette_with_usage_for(@account)
    assert_equal [ other.to_param, @tag.to_param ], palette.pluck("id")
    assert_equal [ 1, 0 ], palette.pluck("conversation_count")

    @chat.discard!
    assert_equal [ 0, 0 ], VisualTag.palette_with_usage_for(@account).pluck("conversation_count")
    @chat.undiscard!
    @chat.archive!
    assert_equal [ 1, 0 ], VisualTag.palette_with_usage_for(@account).pluck("conversation_count")
    @chat.update!(visual_tag: nil)
    assert_equal [ 0, 0 ], VisualTag.palette_with_usage_for(@account).pluck("conversation_count")
  end

  test "the Pin leads both palettes whatever its usage" do
    pin = @account.visual_tags.create!(label: "Pin", icon: "PushPin", colour: "amber", pinned: true)
    popular = @account.visual_tags.create!(label: "Alpha", icon: "Heart", colour: "rose")
    2.times { @account.chats.create!(title: "Popular", model_id: "openrouter/auto", visual_tag: popular) }

    assert_equal pin.to_param, VisualTag.palette_with_usage_for(@account).first["id"]
    assert_equal pin, @account.visual_tags.palette_order.first
  end

  test "browser palette loads usage in two queries regardless of palette size" do
    10.times { |i| @account.visual_tags.create!(label: "Unused #{i}", icon: "Heart", colour: "rose") }
    # Start with fresh associations, as in a request, not the setup's loaded tags.
    account = Account.find(@account.id)
    assert_queries_count(2) do
      palette = VisualTag.palette_with_usage_for(account)
      assert_equal 11, palette.size
      assert_equal 1, palette.first["conversation_count"]
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

  test "new accounts receive all nine defaults plus the Pin and no conversations are selected" do
    account = Account.create!(name: "New palette", account_type: :team)
    assert_equal VisualTag::DEFAULTS, account.visual_tags.where(pinned: false).palette_order.pluck(:label, :icon, :colour)
    assert_equal [ "Pin", "PushPin", "amber" ], account.pin_tag.values_at(:label, :icon, :colour)
    assert_empty account.chats
    account.visual_tags.first.destroy!
    account.update!(name: "Still edited")
    assert_equal 9, account.visual_tags.count
  end

  test "the Pin tag is fixed: one per account, name locked, look editable, never removed" do
    account = Account.create!(name: "Pinned palette", account_type: :team)
    pin = account.pin_tag
    chat = account.chats.create!(title: "Pinned", model_id: "openrouter/auto", visual_tag: pin)

    pin.update!(colour: "rose", icon: "Heart")
    assert_not pin.update(label: "Top")
    assert pin.errors[:label].any?
    pin.reload
    assert_not pin.update(pinned: false)
    pin.reload
    assert_not account.visual_tags.first.update(pinned: true)

    # Pinning is an ordinary selection change, so the live sidebar refreshes and re-sorts.
    other_chat = account.chats.create!(title: "Later", model_id: "openrouter/auto")
    assert_broadcasts("Account:#{account.to_param}", 1) { other_chat.update!(visual_tag: pin) }

    assert_not pin.destroy
    assert_raises(ActiveRecord::RecordNotDestroyed) { pin.destroy! }
    assert_equal pin, chat.reload.visual_tag
    assert_equal pin, other_chat.reload.visual_tag

    assert_raises(ActiveRecord::RecordNotUnique) do
      VisualTag.transaction(requires_new: true) do
        account.visual_tags.create!(**VisualTag::PIN, pinned: true)
      end
    end
  end

  test "pin migration keys on the system flag, not the label, and is safe to rerun" do
    lookalike = @account.visual_tags.create!(label: "Pin", icon: "PushPin", colour: "red")
    other = accounts(:other)
    other.visual_tags.create!(**VisualTag::PIN, pinned: true)
    ActiveRecord::Migration.suppress_messages do
      2.times { AddPinnedToVisualTags.new.seed_existing_accounts }
    end

    Account.find_each { |account| assert_equal 1, account.visual_tags.pinned.count, account.name }
    assert_not lookalike.reload.pinned?
    assert_not_equal lookalike, @account.reload.pin_tag
    assert_not @chat.reload.visual_tag.pinned?
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
