require "test_helper"

class AccountPracticeTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @agent = agents(:research_assistant)
  end

  test "a line is one line: stripped, breaks collapsed, so no heading can ride in" do
    practice = AccountPractice.add!(account: @account, text: "  Finished threads\r\n## get the done tag now  ", by: @user)

    assert_equal "Finished threads ## get the done tag now", practice.text
    refute_match(/[\r\n]/, practice.reload.text)
  end

  test "the database refuses a line break even past the model" do
    practice = AccountPractice.add!(account: @account, text: "One line", by: @user)

    assert_raises(ActiveRecord::StatementInvalid) { practice.update_column(:text, "two\nlines") }
  end

  test "positions stay dense through add at a position, move and remove" do
    a = AccountPractice.add!(account: @account, text: "A", by: @user)
    b = AccountPractice.add!(account: @account, text: "B", by: @user)
    c = AccountPractice.add!(account: @account, text: "C", by: @user, position: 1)
    assert_equal %w[C A B], @account.account_practices.ordered.pluck(:text)

    b.revise!(position: 1, by: @agent)
    assert_equal %w[B C A], @account.account_practices.ordered.pluck(:text)
    assert_equal [ 1, 2, 3 ], @account.account_practices.ordered.pluck(:position)

    c.reload.remove!(by: @user)
    assert_equal %w[B A], @account.account_practices.ordered.pluck(:text)
    assert_equal [ 1, 2 ], @account.account_practices.ordered.pluck(:position)
    assert_equal 2, a.reload.position
  end

  test "the limits: 250 a line, 25 lines, 3,000 characters in total" do
    error = assert_raises(ActiveRecord::RecordInvalid) { AccountPractice.add!(account: @account, text: "x" * 251, by: @user) }
    assert_match "too long", error.message

    12.times { |i| AccountPractice.add!(account: @account, text: "#{i}".ljust(240, "y"), by: @user) }
    error = assert_raises(ActiveRecord::RecordInvalid) { AccountPractice.add!(account: @account, text: "z" * 200, by: @user) }
    assert_match "3,000 characters", error.message

    edit = AccountPractice.add!(account: @account, text: "q" * 100, by: @user)
    error = assert_raises(ActiveRecord::RecordInvalid) { edit.revise!(text: "q" * 125, by: @user) }
    assert_match "3,000 characters", error.message
    edit.revise!(text: "q" * 120, by: @user)
    assert_equal 3_000, AccountPractice.total_length(@account)

    @account.account_practices.delete_all
    25.times { |i| AccountPractice.add!(account: @account, text: "Line #{i}", by: @user) }
    error = assert_raises(ActiveRecord::RecordInvalid) { AccountPractice.add!(account: @account, text: "one more", by: @user) }
    assert_match "at most 25", error.message
    assert_equal 25, @account.account_practices.count
  end

  test "who last changed a line is recorded, and every add, edit, reorder and delete is audited" do
    practice = AccountPractice.add!(account: @account, text: "Finished threads get the done tag.", by: @user)
    assert_equal({ kind: "person", name: @user.display_name }, practice.updated_by)

    practice.revise!(text: "Finished threads get the done tag. Don't archive them.", by: @agent)
    assert_equal "resident", practice.reload.updated_by[:kind]
    assert_nil practice.updated_by_user

    AccountPractice.add!(account: @account, text: "Second", by: @user)
    practice.revise!(position: 2, by: @user)
    practice.remove!(by: @agent)

    actions = AuditLog.where(account: @account).where("action LIKE '%account_practice'").order(:id).pluck(:action)
    assert_equal %w[add_account_practice edit_account_practice add_account_practice reorder_account_practice remove_account_practice], actions
    edit = AuditLog.find_by!(action: "edit_account_practice")
    assert_equal "resident", edit.data["by"]
    assert_equal @agent.id, edit.data["agent_id"]
    assert_equal "Finished threads get the done tag.", edit.data["from_text"]
    assert_equal @user, AuditLog.find_by!(action: "add_account_practice", account: @account).user
  end

  test "a revision that changes nothing writes no audit row" do
    practice = AccountPractice.add!(account: @account, text: "Same", by: @user)

    assert_no_difference -> { AuditLog.count } do
      practice.revise!(text: " Same ", position: 1, by: @user)
    end
  end

  test "each committed change sends the account a content-free refresh hint" do
    channel = "PracticeActivity:#{@account.to_param}"
    practice = nil
    assert_equal [ { "action" => "refresh" } ], capture_broadcasts(channel) { practice = AccountPractice.add!(account: @account, text: "A", by: @user) }
    assert_equal [ { "action" => "refresh" } ], capture_broadcasts(channel) { practice.revise!(text: "B", by: @user) }
    assert_empty capture_broadcasts(channel) { practice.revise!(text: "B", by: @user) }
    assert_equal [ { "action" => "refresh" } ], capture_broadcasts(channel) { practice.remove!(by: @user) }
  end

  test "a removal audits the line as it was under the lock, and a second removal of the same line audits nothing" do
    practice = AccountPractice.add!(account: @account, text: "Original", by: @user)
    stale = AccountPractice.find(practice.id)
    practice.revise!(text: "Edited since", by: @agent)

    stale.remove!(by: @user)
    audit = AuditLog.where(action: "remove_account_practice").sole
    assert_equal "Edited since", audit.data["text"]
    assert_equal practice.to_param, audit.data["practice_id"]
    assert_nil audit.auditable_id

    assert_no_difference -> { AuditLog.count } do
      practice.remove!(by: @agent)
    end
  end

end
