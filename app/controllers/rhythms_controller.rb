class RhythmsController < ApplicationController

  require_feature_enabled :agents
  before_action :set_rhythm, only: %i[show edit update destroy pause resume start]
  before_action :require_manager, only: %i[edit update destroy pause resume start]
  rescue_from ActiveRecord::RecordInvalid do |error|
    redirect_to account_rhythm_path(current_account, @rhythm), alert: error.record.errors.full_messages.to_sentence
  end

  def index
    render inertia: "rhythms/index", props: shared_props.merge(
      rhythms: Rhythm.where(account: current_account).includes(:creator, :agents, :open_holds)
        .order(:title).map { |rhythm| rhythm_payload(rhythm) }
    )
  end

  def show
    render inertia: "rhythms/show", props: shared_props.merge(rhythm: rhythm_payload(@rhythm, history: true))
  end

  def new
    @rhythm = Rhythm.new(account: current_account, creator: Current.user, cadence: "weekly",
      weekday: 1, month_day: 1, month: 1, time_of_day: "09:00",
      timezone: Current.user.timezone.presence || "UTC", append_date: true)
    render_form
  end

  def create
    @rhythm = Rhythm.new(account: current_account, creator: Current.user)
    @rhythm.assign_attributes(rhythm_params)
    save_rhythm
  end

  def edit
    render_form
  end

  def update
    @rhythm.with_lock do
      @rhythm.assign_attributes(rhythm_params)
      save_rhythm
    end
  end

  def destroy
    @rhythm.with_lock { @rhythm.destroy! }
    redirect_to account_rhythms_path(current_account), notice: "Rhythm deleted. Its conversations remain."
  end

  def preview
    rhythm = Rhythm.new(account: current_account, creator: Current.user, **rhythm_params)
    if rhythm.valid?
      at = rhythm.next_occurrence(after: Time.current)
      render json: { next_run_at: at.iso8601, preview_title: rhythm.preview_title(at: at),
        schedule_description: RhythmPresentation.new(rhythm, user: Current.user).schedule_description }
    else
      render json: { errors: rhythm.errors.to_hash(true) }, status: :unprocessable_entity
    end
  end

  def pause
    result = @rhythm.pause!(holder: Current.user, reason: params[:reason].to_s.presence || "Paused by #{Current.user.full_name}")
    redirect_result(result, "Rhythm paused.")
  end

  def resume
    result = @rhythm.resume!(holder: Current.user)
    redirect_result(result, result.status == :active ? "Rhythm resumed." : "Other holds still pause this rhythm.")
  end

  def start
    result = @rhythm.fire!(now: Time.current, manual: true, request_key: params[:request_key])
    if result.created? || result.duplicate?
      redirect_result(result, "Manual occurrence created. The regular schedule is unchanged.")
    else
      redirect_to account_rhythm_path(current_account, @rhythm), alert: result.reason.presence || "Rhythm could not start."
    end
  end

  private

  def set_rhythm
    @rhythm = Rhythm.where(account: current_account).find(params[:id])
  end

  def require_manager
    deny_account_access!("Only the creator or account owner can manage this rhythm.") unless @rhythm.manageable_by?(Current.user)
  end

  def rhythm_params
    permitted = params.require(:rhythm).permit(:title, :opening, :append_date, :cadence, :time_of_day,
      :weekday, :month_day, :month, :timezone, resident_ids: [])
    if permitted.key?(:resident_ids)
      ids = permitted.delete(:resident_ids).reject(&:blank?)
      permitted[:resident_ids] = current_account.conversation_agents.eligible_for_conversation
        .find(Agent.decode_id(ids)).map(&:id)
    end
    permitted.to_h.symbolize_keys
  end

  def save_rhythm
    if @rhythm.valid?
      @rhythm.next_run_at = @rhythm.next_occurrence(after: Time.current)
      @rhythm.save!
      redirect_to account_rhythm_path(current_account, @rhythm), notice: "Rhythm saved."
    else
      render_form(status: :unprocessable_entity)
    end
  end

  def render_form(status: :ok)
    render inertia: "rhythms/form", props: shared_props.merge(
      rhythm: rhythm_payload(@rhythm), errors: @rhythm.errors.to_hash(true)
    ), status: status
  end

  def redirect_result(result, notice)
    options = result.success? ? { notice: notice } : { alert: result.reason.presence || "Rhythm could not start (#{result.status})." }
    redirect_to account_rhythm_path(current_account, @rhythm), **options
  end

  def rhythm_payload(rhythm, history: false)
    RhythmPresentation.new(rhythm, user: Current.user).as_json(history: history)
  end

  def shared_props
    {
      account: current_account.as_json,
      residents: current_account.conversation_agents.eligible_for_conversation.order(:name).map do |agent|
        { id: agent.to_param, name: agent.name, colour: agent.colour, paused: agent.paused? }
      end,
      timezones: ActiveSupport::TimeZone.all.map { |zone| { value: zone.name, label: zone.to_s, identifier: zone.tzinfo.identifier } }
    }
  end

end
