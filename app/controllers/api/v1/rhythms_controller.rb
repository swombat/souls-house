module Api
  module V1
    # Rhythms for residents and people. Resident keys keep their own rules:
    # self creation, self join/leave, creator-only management and holds of
    # their own. A person (account key or OAuth app token) gets what the web
    # Rhythms pages give a signed-in member: any member may list, read,
    # preview and create (choosing residents); the creator or account owner
    # may edit, delete, pause, resume and start. Each path is chosen once per
    # request by `human_key?` and the two never share authority checks. A
    # person's authority is always checked against the rhythm's own account
    # (ApiHumanActor), so an OAuth token reaches rhythms in every enabled
    # account the person belongs to; account_id only narrows.
    class RhythmsController < BaseController

      PAGE_SIZE = 100
      FORBIDDEN_FIELDS = %w[resident_ids agent_ids agents creator creator_id creator_agent creator_agent_id user_id].freeze
      # A human chooses residents the way the web form does, with resident_ids.
      HUMAN_FORBIDDEN_FIELDS = (FORBIDDEN_FIELDS - %w[resident_ids]).freeze
      HUMAN_MANAGER_ACTIONS = %i[update destroy pause resume start].freeze

      before_action :require_human_rhythm_access, if: :human_key?
      before_action :require_resident_action, only: %i[join leave]
      before_action :require_human_actor!, only: :start
      before_action :set_rhythm, except: %i[index create preview]
      before_action :require_human_manager, only: HUMAN_MANAGER_ACTIONS, if: :human_key?
      before_action :require_rhythm_object, only: %i[create update preview]
      before_action :reject_attribution_or_selection, only: %i[create update]
      rescue_from ActiveRecord::RecordInvalid do |error|
        render json: { errors: error.record.errors.to_hash(true) }, status: :unprocessable_entity
      end

      def index
        scope = Rhythm.where(account: rhythm_account).order(id: :desc)
        unless params[:cursor].nil? || (params[:cursor].is_a?(String) && params[:cursor].match?(/\A[a-zA-Z0-9]{0,100}\z/))
          return render json: { error: "Invalid cursor" }, status: :unprocessable_entity
        end
        if params[:cursor].present?
          cursor = scope.find(params[:cursor])
          scope = scope.where("rhythms.id < ?", cursor.id)
        end
        rhythms = scope.includes(:creator, :creator_agent, :agents, :open_holds).limit(PAGE_SIZE + 1).to_a
        response.headers["Cache-Control"] = "no-store"
        render json: {
          # Humans see the recent runs the web list shows; residents' discovery
          # grants no occurrence access.
          rhythms: rhythms.first(PAGE_SIZE).map { |rhythm| presentation(rhythm).as_json(recent: human_key?) },
          next_cursor: rhythms.length > PAGE_SIZE ? rhythms[PAGE_SIZE - 1].to_param : nil
        }
      end

      def show
        render_state(history: human_key?)
      end

      def create
        return human_create if human_key?

        current_api_agent.require_conversation_runtime!
        @rhythm = Rhythm.create!(rhythm_params.merge(
          account: requested_account, creator_agent: current_api_agent, agents: [ current_api_agent ]
        ))
        render_state(status: :created)
      end

      def update
        return human_update if human_key?

        @rhythm.with_lock do
          return render_state(Rhythm::Result.new(status: :forbidden)) unless @rhythm.manageable_by_agent?(current_api_agent)

          @rhythm.update!(rhythm_params)
        end
        render_state
      end

      def destroy
        @rhythm.with_lock do
          unless human_key? || @rhythm.manageable_by_agent?(current_api_agent)
            return render_state(Rhythm::Result.new(status: :forbidden))
          end

          @rhythm.destroy!
        end
        head :no_content
      end

      def preview
        preview = Rhythm::Preview.new(account: rhythm_account, creator: human_key? ? current_api_user : nil,
          creator_agent: current_api_agent, attributes: params[:rhythm].permit(*Rhythm::Preview::ATTRIBUTES))
        response.headers["Cache-Control"] = "no-store"
        if preview.valid?
          render json: preview.as_json
        else
          render json: { errors: preview.errors }, status: :unprocessable_entity
        end
      end

      def join
        render_state(@rhythm.join!(agent: current_api_agent))
      end

      def leave
        render_state(@rhythm.leave!(agent: current_api_agent))
      end

      # A human hold is the person's own: it sits beside residents' holds and
      # the model's human resume never releases a resident's hold.
      def pause
        holder = current_api_agent || current_api_user
        name = current_api_agent ? current_api_agent.name : current_api_user.full_name
        result = @rhythm.pause!(holder: holder, reason: params[:reason].to_s.presence || "Paused by #{name}")
        render_state(result)
      end

      def resume
        result = @rhythm.resume!(holder: current_api_agent || current_api_user)
        render_state(result)
      end

      # Manual start, as the web's "Start now". The request key makes a retry
      # return the same occurrence rather than open another conversation.
      def start
        result = @rhythm.fire!(now: Time.current, manual: true, request_key: params[:request_key])
        occurrence = result.occurrence
        response.headers["Cache-Control"] = "no-store"
        render json: {
          rhythm: presentation(@rhythm.reload).as_json(history: true),
          result: result.status, reason: result.reason,
          occurrence: occurrence && {
            id: occurrence.id.to_s, conversation_id: occurrence.chat&.to_param,
            scheduled_for: occurrence.scheduled_for.iso8601, manual: occurrence.manual
          }
        }, status: case result.status
                   when :created then :created
                   when :duplicate then :ok
                   when :invalid_request then :unprocessable_entity
                   else :conflict
                   end
      end

      private

      # A person, through an account key or an OAuth app token.
      def human_key?
        current_api_agent.nil?
      end

      # The web Rhythms pages sit behind the agents feature switch. Membership
      # is checked against the account each action acts in (human_account!).
      def require_human_rhythm_access
        return if Setting.instance.allow_agents?

        render json: { error: "This feature is currently disabled" }, status: :forbidden
      end

      # The account a person's list, preview or create acts in: the one
      # account_id names, otherwise the key's account or the person's default.
      def human_rhythm_account
        @human_rhythm_account ||= human_account!(requested_account)
      end

      def rhythm_account
        human_key? ? human_rhythm_account : requested_account
      end

      def require_resident_action
        return unless human_key?

        render json: { error: "Join and leave are for resident keys; choose residents with rhythm[resident_ids]" },
          status: :forbidden
      end

      def require_human_manager
        return if @rhythm.manageable_by?(current_api_user)

        render json: { error: "Only the creator or account owner can manage this rhythm." }, status: :forbidden
      end

      def set_rhythm
        return set_human_rhythm if human_key?

        # Discovery grants no occurrence/chat access. A departed guest loses
        # this account door even when it still owns a surviving hold.
        reachable = Account.where(id: current_api_account.id)
          .or(Account.where(id: current_api_agent.guest_memberships.select(:account_id)))
        reachable = reachable.where(id: requested_account.id) if params[:account_id].present?
        @rhythm = Rhythm.where(account: reachable).find(params[:id])
      end

      # An account key reaches its own account; an OAuth token reaches every
      # account the person may act in, or only the one account_id names. Then
      # the rhythm's own account must pass the membership check.
      def set_human_rhythm
        scope = if app_token_request? && params[:account_id].blank?
          Rhythm.where(account_id: current_api_user.confirmed_accounts.select(:id))
        else
          Rhythm.where(account: requested_account)
        end
        @rhythm = scope.find(params[:id])
        human_account!(@rhythm.account)
      end

      def reject_attribution_or_selection
        forbidden = human_key? ? HUMAN_FORBIDDEN_FIELDS : FORBIDDEN_FIELDS
        fields = params.keys & forbidden
        fields |= params[:rhythm].keys & forbidden if params[:rhythm].is_a?(ActionController::Parameters)
        return if fields.empty?

        message = if human_key?
          "Creator cannot be supplied; choose residents with resident_ids"
        else
          "Creator and resident selection cannot be supplied; use self join/leave"
        end
        render json: { errors: { rhythm: [ message ] } }, status: :unprocessable_entity
      end

      def require_rhythm_object
        return if params[:rhythm].is_a?(ActionController::Parameters)

        render json: { errors: { rhythm: [ "must be an object" ] } }, status: :unprocessable_entity
      end

      def rhythm_params
        params[:rhythm].permit(:title, :opening, :append_date, :cadence, :time_of_day,
          :weekday, :month_day, :month, :timezone).to_h.symbolize_keys
      end

      # The web form's parameters: resident_ids are resolved against the
      # account's eligible residents and accepted guests, failing closed (404).
      def human_rhythm_params(account)
        permitted = params[:rhythm].permit(:title, :opening, :append_date, :cadence, :time_of_day,
          :weekday, :month_day, :month, :timezone, resident_ids: [])
        if permitted.key?(:resident_ids)
          permitted[:resident_ids] = Rhythm.selectable_resident_ids(account, permitted.delete(:resident_ids))
        end
        permitted.to_h.symbolize_keys
      end

      def human_create
        @rhythm = Rhythm.new(account: human_rhythm_account, creator: current_api_user)
        @rhythm.assign_attributes(human_rhythm_params(human_rhythm_account))
        return render_validation_errors unless @rhythm.save_from_form

        render_state(status: :created, history: true)
      end

      # The shared form update: a rejected edit rolls back its selection too.
      def human_update
        attributes = human_rhythm_params(@rhythm.account)
        return render_validation_errors unless @rhythm.with_lock { @rhythm.update_from_form(attributes) }

        render_state(history: true)
      end

      def render_validation_errors
        render json: { errors: @rhythm.errors.to_hash(true) }, status: :unprocessable_entity
      end

      def presentation(rhythm)
        if human_key?
          RhythmPresentation.new(rhythm, user: current_api_user)
        else
          RhythmPresentation.new(rhythm, agent: current_api_agent)
        end
      end

      def render_state(result = nil, status: :ok, history: false)
        response.headers["Cache-Control"] = "no-store"
        render json: {
          rhythm: presentation(@rhythm).as_json(history: history),
          result: result&.status, reason: result&.reason
        }, status: case result&.status
                   when :forbidden then :forbidden
                   when :unavailable then :conflict
                   else status
                   end
      end

    end
  end
end
