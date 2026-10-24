# The stalled-thread sweeper's verdicts, newest first, with what each one did
# (who was woken, who was held back and why), for a person to read against
# what happened next.
class Admin::StalledSweepsController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin

  LIMIT = 200

  def index
    sweeps = StalledThreadSweep.includes(:chat, :account, :message).order(created_at: :desc)
    sweeps = sweeps.where(outcome: params[:outcome]) if StalledThreadSweep::OUTCOMES.include?(params[:outcome])
    render inertia: "admin/stalled-sweeps", props: {
      interval_minutes: Setting.instance.stalled_sweep_minutes,
      waking: Setting.instance.stalled_sweep_wake?,
      outcome: params[:outcome].presence,
      counts: StalledThreadSweep.where(created_at: 7.days.ago..).group(:outcome).count,
      sweeps: sweeps.limit(LIMIT).map { |sweep| present(sweep) }
    }
  end

  private

  def present(sweep)
    chat = sweep.chat
    {
      id: sweep.id,
      at: sweep.created_at.iso8601,
      outcome: sweep.outcome,
      would_wake: sweep.would_wake,
      person_holds: sweep.person_holds,
      scores: sweep.scores,
      quiet_minutes: sweep.quiet_minutes,
      error_class: sweep.error_class,
      woken: Agent.where(id: sweep.woken_agent_ids).pluck(:name),
      held: sweep.held,
      stopped: sweep.stopped,
      account: sweep.account.name,
      chat: { id: chat.to_param, title: chat.title.presence || "Untitled", path: "/accounts/#{sweep.account.to_param}/chats/#{chat.to_param}" },
      message_id: sweep.message.obfuscated_id,
      moved_on: chat.messages.kept.where("id > ?", sweep.message_id).exists?
    }
  end

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end
