require "test_helper"
require "action_cable/test_helper"

class RhythmActivityTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  # Exercise actual outer commits, including the explicit bulk-release hook.
  self.use_transactional_tests = false

  setup do
    @user = users(:user_1)
    @account = Account.create!(name: "Rhythm commit #{SecureRandom.hex(4)}", account_type: "team")
    @account.memberships.create!(user: @user, role: "owner", confirmed_at: Time.current)
    @agent = @account.agents.create!(name: "Synthetic rhythm resident", runtime: "external",
      model_id: "anthropic/claude-opus-5.5", switchable_model_ids: [ "anthropic/claude-fable-5.1" ])
    @other_agent = @account.agents.create!(name: "Other synthetic resident", runtime: "external",
      model_id: "anthropic/claude-opus-5.5")
    @rhythm = build_rhythm
    @rhythm.save!
  end

  teardown do
    @rhythm.destroy! if @rhythm && Rhythm.exists?(@rhythm.id)
    @account.destroy!
  end

  test "the reusable broadcaster sends only a refresh to the account stream" do
    assert_no_broadcasts(stream(accounts(:existing_user_account))) do
      assert_equal [ { "action" => "refresh" } ], capture_broadcasts(stream) { RhythmActivity.broadcast_for(@account) }
    end
    assert_no_broadcasts(stream) { RhythmActivity.broadcast_for(nil) }
  end

  test "broadcast failure does not turn committed work into an error" do
    ActionCable.server.stub(:broadcast, ->(*) { raise IOError, "synthetic cable failure" }) do
      assert_nothing_raised { RhythmActivity.broadcast_for(@account) }
    end
  end

  %i[rhythm hold seat occurrence].each do |kind|
    test "#{kind} lifecycle emits content-free markers only after commit" do
      record = build_record(kind)
      assert_refresh_after_commit { record.save! }
      assert_refresh_after_commit { update_record(record) }
      assert_refresh_after_commit { record.destroy! }
    end

    test "#{kind} rollback emits nothing for create update or destroy" do
      record = build_record(kind)
      assert_rollback_without_refresh { record.save! }
      assert_not record.persisted?

      # A rolled-back autosaved selection can retain in-memory join objects.
      record = build_record(kind)
      record.save!
      before = record.updated_at
      assert_rollback_without_refresh { update_record(record) }
      assert_equal before, record.reload.updated_at
      assert_rollback_without_refresh { record.destroy! }
      assert record.class.exists?(record.id)
      record.destroy!
    end

    test "#{kind} never refreshes another accounts rhythms" do
      record = build_record(kind)
      assert_no_broadcasts(stream(accounts(:existing_user_account))) do
        record.save!
        update_record(record)
        record.destroy!
      end
    end
  end

  test "join leave and model pins refresh without saving the parent" do
    before = @rhythm.updated_at
    assert_refresh_after_commit { @rhythm.join!(agent: @other_agent) }
    assert_refresh_after_commit { @rhythm.join!(agent: @agent, model_id: "anthropic/claude-fable-5.1") }
    assert_refresh_after_commit { @rhythm.leave!(agent: @other_agent) }
    assert_equal before, @rhythm.reload.updated_at
    assert_equal "anthropic/claude-fable-5.1", @rhythm.resident_models[@agent.id]
  end

  test "manual firing refreshes through its occurrence without advancing the parent" do
    before = @rhythm.updated_at
    next_run = @rhythm.next_run_at
    result = nil
    MessageDispatchJob.stub(:perform_later, ->(*) {}) do
      assert_refresh_after_commit do
        result = @rhythm.fire!(manual: true, request_key: "synthetic-manual")
      end
      assert_equal :created, result.status
      assert_no_broadcasts(stream) do
        assert_equal :duplicate, @rhythm.reload.fire!(manual: true, request_key: "synthetic-manual").status
      end
    end
    assert_equal before, @rhythm.reload.updated_at
    assert_equal next_run, @rhythm.next_run_at
  end

  test "scheduled firing refreshes and advances the schedule without invoking a resident" do
    now = Time.utc(2026, 10, 16, 10)
    @rhythm.update_column(:next_run_at, now - 1.day)
    MessageDispatchJob.stub(:perform_later, ->(*) {}) do
      assert_refresh_after_commit { assert_equal :created, @rhythm.fire!(now: now).status }
    end
    assert_operator @rhythm.reload.next_run_at, :>, now
  end

  %i[human agent].each do |holder_kind|
    test "#{holder_kind} bulk resume refreshes after the outer commit while another hold remains" do
      holder = holder_kind == :human ? @user : @agent
      other = holder_kind == :human ? @agent : @user
      @rhythm.pause!(holder: holder, reason: "Release this")
      @rhythm.pause!(holder: other, reason: "Keep this")
      before = @rhythm.updated_at

      assert_refresh_after_commit do
        assert_equal :held, @rhythm.resume!(holder: holder).status
        assert_equal [ other.is_a?(User) ? "human" : "agent" ], @rhythm.open_holds.pluck(:kind)
      end
      assert_equal before, @rhythm.reload.updated_at
      assert_equal 1, @rhythm.holds.where.not(released_at: nil).count
    end

    test "#{holder_kind} bulk resume outer rollback preserves holds and emits nothing" do
      holder = holder_kind == :human ? @user : @agent
      other = holder_kind == :human ? @agent : @user
      @rhythm.pause!(holder: holder, reason: "Release this")
      @rhythm.pause!(holder: other, reason: "Keep this")

      assert_rollback_without_refresh { assert_equal :held, @rhythm.resume!(holder: holder).status }
      assert_equal 2, @rhythm.open_holds.count
      assert_equal 0, @rhythm.holds.where.not(released_at: nil).count
    end
  end

  test "a rolled back resume savepoint cannot leak a refresh when the outer transaction commits" do
    @rhythm.pause!(holder: @user, reason: "Human hold")
    @rhythm.pause!(holder: @agent, reason: "Resident hold")

    assert_no_broadcasts(stream) do
      Rhythm.transaction do
        Rhythm.transaction(requires_new: true) do
          assert_equal :held, @rhythm.resume!(holder: @user).status
          raise ActiveRecord::Rollback
        end
      end
    end
    assert_equal 2, @rhythm.open_holds.count
  end

  test "resident creator can release system holds in bulk while a human hold remains" do
    @rhythm.update!(creator: nil, creator_agent: @agent)
    @rhythm.pause!(holder: :system, reason: "Synthetic resolved problem")
    @rhythm.pause!(holder: @user, reason: "Keep this")
    before = @rhythm.updated_at

    assert_refresh_after_commit { assert_equal :held, @rhythm.resume!(holder: @agent).status }
    assert_equal [ "human" ], @rhythm.open_holds.pluck(:kind)
    assert_equal before, @rhythm.reload.updated_at
  end

  test "last hold resume refreshes and advances without changing hold semantics" do
    @rhythm.pause!(holder: @agent, reason: "Release this")
    @rhythm.update_column(:next_run_at, 1.day.ago)
    assert_refresh_after_commit { assert_equal :active, @rhythm.resume!(holder: @agent).status }
    assert_not @rhythm.held?
    assert_operator @rhythm.reload.next_run_at, :>, Time.current
  end

  test "forbidden and no-op partial resume emit nothing" do
    @rhythm.pause!(holder: @agent, reason: "Keep this")
    assert_no_broadcasts(stream) do
      assert_equal :forbidden, @rhythm.resume!(holder: @other_agent).status
      assert_equal :held, @rhythm.resume!(holder: @user).status
    end
  end

  test "parent deletion refreshes despite child destruction and callback-free occurrence nullification" do
    occurrence = build_record(:occurrence)
    occurrence.save!
    @rhythm.pause!(holder: @agent, reason: "Retain consent history")
    assert_refresh_after_commit { @rhythm.destroy! }
    assert_nil occurrence.reload.rhythm_id
    assert_empty RhythmAgent.where(rhythm_id: @rhythm.id)
    assert_empty RhythmHold.where(rhythm_id: @rhythm.id)
    assert_no_broadcasts(stream) { occurrence.update!(title: "Retained snapshot") }
  end

  test "ordinary messages and touches in a rhythm run do not refresh rhythms" do
    occurrence = build_record(:occurrence)
    occurrence.save!
    assert_no_broadcasts(stream) do
      occurrence.chat.messages.create!(role: "assistant", agent: @agent, content: "Synthetic reply",
        suppress_automatic_dispatch: true)
      occurrence.chat.touch
    end
  end

  private

  def stream(account = @account)
    "RhythmActivity:#{account.obfuscated_id}"
  end

  def assert_refresh_after_commit
    messages = capture_broadcasts(stream) do
      assert_no_broadcasts(stream(accounts(:existing_user_account))) do
        Rhythm.transaction do
          assert_no_broadcasts(stream) { yield }
        end
      end
    end
    assert_not_empty messages
    assert messages.all? { |message| message == { "action" => "refresh" } }
  end

  def assert_rollback_without_refresh
    assert_no_broadcasts(stream) do
      Rhythm.transaction(requires_new: true) do
        yield
        raise ActiveRecord::Rollback
      end
    end
  end

  def build_rhythm
    Rhythm.new(account: @account, creator: @user, title: "Synthetic invitation", opening: "Synthetic opening",
      agents: [ @agent ], cadence: "daily", time_of_day: "09:00", timezone: "UTC")
  end

  def build_record(kind)
    case kind
    when :rhythm then build_rhythm
    when :hold then @rhythm.holds.new(kind: "human", user: @user, reason: "Synthetic pause")
    when :seat then @rhythm.rhythm_agents.new(agent: @other_agent)
    when :occurrence
      chat = @account.chats.create!(title: "Synthetic run", manual_responses: true, agents: [ @agent ])
      message = chat.messages.create!(role: "user", user: @user, content: "Synthetic opening",
        suppress_automatic_dispatch: true)
      @rhythm.occurrences.new(chat: chat, message: message, creator: @user, creator_label: "Synthetic human",
        title: "Synthetic run", rhythm_title: @rhythm.title, opening: "Synthetic opening", scheduled_for: Time.current)
    end
  end

  def update_record(record)
    case record
    when Rhythm then record.update!(title: "Synthetic edit")
    when RhythmHold then record.update!(reason: "Edited synthetic reason")
    when RhythmAgent then record.update!(model_id: "anthropic/claude-opus-5.5")
    when RhythmOccurrence then record.update!(title: "Edited synthetic run")
    end
  end

end
