module Chat::CompletionWorkflow

  extend ActiveSupport::Concern

  included do
    has_many :work_completions, dependent: :destroy
    has_many :work_completion_permissions, dependent: :destroy
  end

  def with_completion_authority!(agent: nil, user: nil, &block)
    self.class.transaction do
      Account.where(id: account_id, disabled_at: nil).lock("FOR SHARE").take!
      # Grantor membership precedes the chat lock, just like ordinary human
      # authority. A grant created after this snapshot waits for a fresh retry.
      grantors = work_completion_permissions.available.pluck(:user_id)
      @completion_grantor_ids = Membership.confirmed.where(account_id: account_id, user_id: grantors)
        .order(:id).lock("FOR SHARE").pluck(:user_id)
      with_work_status_authority!(agent: agent, user: user, &block)
    ensure
      @completion_grantor_ids = nil
    end
  end

  # Authority and the chat lock must already be held by the caller.
  def grant_completion_permission!(user:, expected_revision:, auto_close:)
    check_completion_revision!(expected_revision)
    raise Chat::WorkStatus::Invalid, "auto_close must be true or false" unless [ true, false ].include?(auto_close)
    Membership.confirmed.find_by!(account_id: account_id, user_id: user.id)
    work_completion_permissions.available.update_all(revoked_at: Time.current)
    work_completion_permissions.create!(user: user, work_revision: work_status_revision, auto_close: auto_close)
  end

  def submit_completion!(agent: nil, user: nil, expected_revision:, request_key:, fields:)
    check_completion_revision_type!(expected_revision)
    unless request_key.is_a?(String) && request_key.present? && request_key.length <= 100 && !request_key.include?("\0")
      raise Chat::WorkStatus::Invalid, "request_key must be nonempty text of at most 100 characters without NUL"
    end
    unless WorkCompletion::FIELDS.all? { |field| fields[field].is_a?(String) && !fields[field].include?("\0") }
      raise Chat::WorkStatus::Invalid, "All four handoff fields must be text without NUL"
    end
    # A retry returns its original receipt, never re-closes or re-accepts work.
    existing = work_completions.find_by(request_key: request_key)
    if existing
      same = existing.agent_id == agent&.id && existing.user_id == user&.id &&
        existing.source_revision == expected_revision &&
        WorkCompletion::FIELDS.all? { |field| existing.public_send(field) == fields[field] }
      raise Chat::WorkStatus::Conflict, "Request key already used for different work" unless same
      return existing
    end
    check_completion_revision!(expected_revision)
    completion = work_completions.build(fields.slice(*WorkCompletion::FIELDS).merge(
      agent: agent, user: user, request_key: request_key, source_revision: work_status_revision,
      review_revision: work_status_revision + 1))
    permission = work_completion_permissions.available.where(work_revision: work_status_revision).order(id: :desc).first
    grantor = permission && @completion_grantor_ids&.include?(permission.user_id)
    text = [ "## Completion handoff", *WorkCompletion::FIELDS.map { |field| "**#{field.humanize}**\n#{completion.public_send(field)}" } ].join("\n\n")
    # A workflow receipt, not a conversational request: it neither generates
    # its own ReplyExpectation nor answers/dismisses anyone else's.
    completion.message = messages.build(role: "system", agent: agent, content: text)
    completion.validate!
    completion.message.save!
    completion.save!
    update!(work_status: "ready_for_review", work_status_reason: nil,
      work_status_since: Time.current, work_status_revision: completion.review_revision)
    if permission && grantor
      permission.update!(consumed_at: Time.current)
      accept_completion!(completion: completion, user: permission.user,
        expected_revision: work_status_revision, auto_close: permission.auto_close,
        closing_agent: agent)
    end
    completion
  end

  def accept_completion!(completion:, user:, expected_revision:, auto_close:, closing_agent: nil)
    check_completion_revision_type!(expected_revision)
    raise Chat::WorkStatus::Invalid, "auto_close must be true or false" unless [ true, false ].include?(auto_close)
    if completion.chat_id == id && completion.accepted_at &&
        completion.accepted_revision == work_status_revision && expected_revision == completion.review_revision
      return completion
    end
    check_completion_revision!(expected_revision)
    raise Chat::WorkStatus::Conflict, "Handoff is no longer current" unless completion.chat_id == id &&
      completion.review_revision == work_status_revision && completion.accepted_at.nil? && completion.message.kept?
    Membership.confirmed.find_by!(account_id: account_id, user_id: user.id)
    revision = work_status_revision + 1
    update!(work_status: "completed", work_status_reason: nil, work_status_since: Time.current, work_status_revision: revision)
    completion.update!(accepted_by: user, accepted_at: Time.current, accepted_revision: revision)
    return completion unless auto_close

    close_completion!(completion: completion, expected_revision: revision, closing_agent: closing_agent)
  end

  def close_completion!(completion:, expected_revision:, closing_agent: nil)
    check_completion_revision_type!(expected_revision)
    if completion.chat_id == id && completion.closed_at && archived? &&
        completion.accepted_revision == work_status_revision && expected_revision == work_status_revision
      return completion
    end
    check_completion_revision!(expected_revision)
    unless completion.chat_id == id && completion.accepted_at && completion.accepted_revision == work_status_revision
      raise Chat::WorkStatus::Conflict, "Only the current accepted handoff can close this work"
    end
    refusal = if closing_agent && closing_agent.account_id != account_id
      { code: "guest_cannot_auto_close", error: "A visiting resident cannot automatically archive its host's conversation" }
    else
      PendingWorkArchiveRefusal.new(self).call
    end
    if refusal
      completion.update!(closure_blocked: refusal)
    else
      archive!
      completion.update!(closed_at: Time.current, closure_blocked: nil)
    end
    completion
  end

  private

  def check_completion_revision!(revision)
    check_completion_revision_type!(revision)
    raise Chat::WorkStatus::Conflict, "Work changed; refresh before completing it" unless revision == work_status_revision
    raise Chat::WorkStatus::Invalid, "Reopen the conversation before changing its completion" unless respondable?
  end

  def check_completion_revision_type!(revision)
    raise Chat::WorkStatus::Invalid, "expected_revision must be a nonnegative integer" unless revision.is_a?(Integer) && revision >= 0
  end

end
