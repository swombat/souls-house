# How a finished run ended, for the room and the resident's card: whether it
# counts toward a failure streak, and a safe category for why it failed.
#
# The category is read from structured fields the run already stores (state,
# runtime status, return code, transport status, the class of a connect
# error), never from stdout, stderr or error text: those can carry
# credentials, prompt fragments and paths, and they stay in the run log that
# the resident's Runs tab and Site Admin show. Where the fields don't
# establish a cause, the category is "unknown" and the room is told so.
module AgentRuntimeInteraction::FailureReport

  extend ActiveSupport::Concern

  FAILURE_STATES = %w[failed timed_out].freeze
  # The house inference gateway's allowance refusal codes
  # (HouseInferenceGrant, ResidentEntitlement), recorded on the run that made
  # the refused call (inference_refusal) or carried by a scheduled run
  # refused before dispatch (InferenceAvailability.scheduled_refusal,
  # refusal_code).
  ALLOWANCE_REFUSALS = %w[house_allowance_exhausted house_allowance_none].freeze
  # Every gateway refusal recorded on a run. house_provider_refused is the
  # house's pinned upstream answering a call with an error status: the
  # house's side, not the owner's (Soul Horse, 1 Nov 2026: every run).
  INFERENCE_REFUSALS = (ALLOWANCE_REFUSALS + %w[house_provider_refused]).freeze
  # Categories that mean the resident can't pay for its model as set up:
  # the owner's fix is setup or money, not repair.
  SETUP_CATEGORIES = %w[needs_setup house_allowance_exhausted house_allowance_none].freeze
  FAILURE_CATEGORIES = %w[
    needs_setup house_allowance_exhausted house_allowance_none house_provider_refused subscription_limit
    runtime_unavailable model_unavailable authentication_error runtime_error timed_out unknown
  ].freeze
  # Runs the house starts on its own clock, with no room to fail in: the
  # scheduled wake and the memory aggregations. Telegram and orientation runs
  # are neither (someone asked, or it ran once at birth).
  SCHEDULED_TRIGGER_KINDS = [ "wake", /\Amemory_aggregation_/ ].freeze
  # The request never reached a runtime that could answer it.
  UNAVAILABLE_ERROR_CLASSES = %w[
    Errno::ECONNREFUSED Errno::EHOSTUNREACH Errno::ENETUNREACH SocketError Net::OpenTimeout
  ].freeze
  UNAVAILABLE_TRANSPORT_STATUSES = [ 502, 503, 504 ].freeze

  included do
    belongs_to :failure_notice_message, class_name: "Message", optional: true
    after_update_commit :enqueue_failure_notice, if: -> {
      (saved_change_to_finished_at? || saved_change_to_execution_state?) && finished_at.present?
    }
  end

  # :failure for a failed or timed-out run; :success for a completed one;
  # :neutral for a run that was busy, lost, cancelled or hasn't finished,
  # which neither counts toward a streak nor ends one.
  def streak_outcome
    return :neutral if finished_at.nil?

    if execution_state.present?
      return :failure if execution_state.in?(FAILURE_STATES)
      return :success if execution_state == "completed"

      return :neutral
    end
    return :neutral if runtime_status == "already_running"
    return :failure if runtime_status == "timeout" || chat_activity_status == "failed"

    :success
  end

  def scheduled_run?
    SCHEDULED_TRIGGER_KINDS.any? { |kind| kind === trigger_kind }
  end

  def failure_category
    return unless streak_outcome == :failure
    # The gateway refused a house inference call made by this run (#678).
    # Ahead of timed_out: a runtime that hangs after the refusal still
    # failed because of it.
    return inference_refusal if inference_refusal.in?(INFERENCE_REFUSALS)
    return "timed_out" if execution_state == "timed_out" || runtime_status == "timeout"
    # The house refused a scheduled run before dispatch because the resident
    # has no usable credential or allowance (InferenceAvailability); when the
    # refusal was the house allowance, its code says which.
    if error_kind == Agents::InferenceAvailability::NEEDS_SETUP
      return refusal_code.in?(ALLOWANCE_REFUSALS) ? refusal_code : "needs_setup"
    end
    return "runtime_unavailable" if error_class.in?(UNAVAILABLE_ERROR_CLASSES)
    return "runtime_unavailable" if runtime_status.nil? && transport_status.in?(UNAVAILABLE_TRANSPORT_STATUSES)
    # The runtime's own structured classification (trigger_shim.py
    # classify_provider_error): the CLI refused the model before any request.
    return "model_unavailable" if error_kind == "model_unavailable"
    # The shim's auth class (classify_provider_error) matches authentication
    # wording or a 401 anywhere in the run's output, so it shows the run
    # looked like an authentication error, not that a credential is missing
    # or expired. The line says only that.
    return "authentication_error" if error_kind == "auth_expired"
    # The shim's limit class (classify_provider_error): usage-limit or 429
    # wording in the run's output. Like auth, it says what the output looked
    # like, not that the subscription is spent.
    return "subscription_limit" if error_kind == "subscription_limit"
    return "runtime_error" if runtime_status == "error" || runtime_returncode.to_i.nonzero?

    "unknown"
  end

  private

  def error_kind
    response_body["error_kind"] if response_body.is_a?(Hash)
  end

  def refusal_code
    response_body["refusal_code"] if response_body.is_a?(Hash)
  end

  def enqueue_failure_notice
    if scheduled_run?
      # Failures open a streak notice, completions close one; neutral ends do neither.
      ScheduledRunFailureNoticeJob.perform_later(id) unless streak_outcome == :neutral
    elsif chat_id && trigger_kind == "conversation" && streak_outcome == :failure
      RunFailureNoticeJob.perform_later(id)
    end
  rescue StandardError => error
    Rails.logger.warn("Run failure notice enqueue failed for interaction #{id}: #{error.class}")
  end

end
