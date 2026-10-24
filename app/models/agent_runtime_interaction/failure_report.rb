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
  FAILURE_CATEGORIES = %w[runtime_unavailable runtime_error timed_out unknown].freeze
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

  def failure_category
    return unless streak_outcome == :failure
    return "timed_out" if execution_state == "timed_out" || runtime_status == "timeout"
    return "runtime_unavailable" if error_class.in?(UNAVAILABLE_ERROR_CLASSES)
    return "runtime_unavailable" if runtime_status.nil? && transport_status.in?(UNAVAILABLE_TRANSPORT_STATUSES)
    return "runtime_error" if runtime_status == "error" || runtime_returncode.to_i.nonzero?

    "unknown"
  end

  private

  def enqueue_failure_notice
    return unless chat_id && trigger_kind == "conversation" && streak_outcome == :failure

    RunFailureNoticeJob.perform_later(id)
  rescue StandardError => error
    Rails.logger.warn("Run failure notice enqueue failed for interaction #{id}: #{error.class}")
  end

end
