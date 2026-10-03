require "test_helper"

class StoneTest < ActiveSupport::TestCase

  HTML = '<!doctype html><html><head><title>A stone</title></head><body><p>Hello</p></body></html>'

  setup do
    @user = users(:confirmed_user)
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(title: "Stones", model_id: "openrouter/auto", agents: [ @agent ])
  end

  test "publication atomically stores the original HTML and one attributed revision" do
    stone = publish
    revision = stone.latest_revision
    assert_equal 1, revision.number
    assert_equal @user, revision.author
    assert_nil revision.agent_id
    assert_equal HTML, revision.html_document
    assert_equal "text/html", revision.html.blob.content_type
    assert revision.html.blob.metadata["stone_html"]
    assert_equal Stone::Document::POLICY_VERSION.to_s, revision.policy_version
    assert_equal "not_requested", revision.preview_status
  end

  test "public tokens are high entropy unique and stable across revisions and withdrawal" do
    stone = publish
    token = stone.public_token
    assert_equal 32, token.length
    assert_not_equal stone.to_param, token
    assert_not_equal publish.public_token, token
    first = stone.latest_revision
    stone.revise!(title: "Second", html: HTML, author: @user, public: true, base_revision_id: first.to_param)
    stone.withdraw!
    assert_equal token, stone.reload.public_token
  end

  test "quota accounts for prior revisions but not other accounts" do
    stone = publish
    first = stone.latest_revision
    first.html.blob.update!(byte_size: Stone::ACCOUNT_HTML_QUOTA)
    assert_no_difference "StoneRevision.count" do
      assert_raises(Stone::InvalidInput) do
        stone.revise!(title: "Too much", html: HTML, author: @user, public: true, base_revision_id: first.to_param)
      end
    end
    other_chat = accounts(:team_account).chats.create!(title: "Separate quota", model_id: "openrouter/auto", agents: [ agents(:other_account_agent) ])
    assert Stone.publish!(chat: other_chat, title: "Allowed", html: HTML, author: @user, public: true)
  end

  test "archived conversations allow delivery and withdrawal but not writes" do
    stone = publish
    first = stone.latest_revision
    @chat.archive!
    assert_equal HTML, first.html_document
    assert_raises(Stone::InvalidInput) { publish }
    assert_raises(Stone::InvalidInput) do
      stone.revise!(title: "No", html: HTML, author: @user, public: true, base_revision_id: first.to_param)
    end
    stone.withdraw!
    assert stone.withdrawn?
  end

  test "invalid publication leaves no stone revision or blob" do
    [ { public: false }, { title: "" }, { html: "<html><body><iframe src=\"https://example.com\"></iframe></body></html>" },
      { html: "x" * (Stone::MAX_HTML_BYTES + 1) } ].each do |attributes|
      assert_no_difference [ "Stone.count", "StoneRevision.count", "ActiveStorage::Blob.count" ] do
        assert_raises(Stone::InvalidInput, Stone::Document::Invalid) { publish(**attributes) }
      end
    end
  end

  test "revisions require the current base and retain prior documents" do
    stone = publish
    first = stone.latest_revision
    second_html = HTML.sub("Hello", "Second")
    second = stone.revise!(title: "Second", html: second_html, author: @agent, public: true, base_revision_id: first.to_param)
    assert_equal 2, second.number
    assert_equal @agent, second.author
    assert_nil second.user_id
    assert_equal first.html_document, HTML
    assert_equal second_html, second.html_document
    assert_equal second, stone.latest_revision

    [ nil, first.to_param, "unknown", first.id ].each do |base|
      assert_no_difference "StoneRevision.count" do
        assert_raises(Stone::Conflict) do
          stone.revise!(title: "Stale", html: HTML, author: @user, public: true, base_revision_id: base)
        end
      end
    end
  end

  test "authored revision fields and the HTML blob cannot be replaced but preview can change" do
    revision = publish.latest_revision
    {
      title: "Changed", number: 20, user_id: users(:existing_user).id,
      agent_id: @agent.id, policy_version: "other", stone_id: publish.id,
      created_at: 1.day.ago
    }.each do |attribute, value|
      assert_not revision.update(attribute => value), attribute.to_s
      revision.reload
    end
    original_blob = revision.html.blob
    assert_raises(ActiveRecord::RecordInvalid) do
      revision.html_document = HTML.sub("Hello", "Replacement")
      revision.save!
    end
    revision.reload
    assert_equal original_blob, revision.html.blob
    revision.update!(preview_status: "failed", preview_error: "Renderer unavailable")
    assert_equal "failed", revision.reload.preview_status
  end

  test "creation requires exactly one author and validated HTML" do
    revision = publish.latest_revision
    assert_not StoneRevision.new(stone: revision.stone, number: 2, title: "Empty", policy_version: "1").valid?
    revision.user = nil
    assert_not revision.valid?
    revision.reload
    revision.agent = @agent
    assert_not revision.valid?
  end

  test "database enforces author and revision number invariants" do
    revision = publish.latest_revision
    assert_raises(ActiveRecord::StatementInvalid) do
      StoneRevision.transaction(requires_new: true) { revision.update_columns(agent_id: @agent.id) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      StoneRevision.transaction(requires_new: true) { revision.update_columns(number: 0) }
    end
    second = revision.stone.revise!(title: "Second", html: HTML, author: @user, public: true, base_revision_id: revision.to_param)
    assert_raises(ActiveRecord::RecordNotUnique) do
      StoneRevision.transaction(requires_new: true) { second.update_columns(number: 1) }
    end
  end

  test "withdrawal blocks reads and revisions immediately and purges asynchronously retaining history" do
    stone = publish
    revision = stone.latest_revision
    blob = revision.html.blob
    assert_enqueued_with(job: ActiveStorage::PurgeJob, args: [ blob ]) { stone.withdraw! }
    assert stone.reload.withdrawn?
    assert_raises(Stone::Withdrawn) { revision.html_document }
    assert_raises(Stone::Withdrawn) do
      stone.revise!(title: "No", html: HTML, author: @user, public: true, base_revision_id: revision.to_param)
    end
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
    assert_not ActiveStorage::Blob.exists?(blob.id)
    assert StoneRevision.exists?(revision.id)
    assert_equal "A stone", revision.reload.title
    assert_not revision.html.attached?
    stone.withdraw!
  end

  test "chat deletion cascades stones revisions and message links" do
    stone = publish
    revision = stone.latest_revision
    message = @chat.messages.create!(role: "assistant", content: "A reference", agent: @agent)
    message.stone_revisions << revision
    assert_difference [ "Stone.count", "StoneRevision.count", "MessageStoneRevision.count" ], -1 do
      @chat.destroy!
    end
  end

  private

  def publish(**attributes)
    Stone.publish!(**{ chat: @chat, title: "A stone", html: HTML, author: @user, public: true }.merge(attributes))
  end

end
