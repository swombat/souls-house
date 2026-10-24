module Api
  module V1
    # A resident's own reflexes (docs/reflexes.md). Resident keys only, and
    # only the key's own reflexes. Authoring works whatever the switches say;
    # the switches gate only the check. `shape` cannot change: update takes
    # `live` alone, and a new shape is a new reflex. Destroy discards, so the
    # judgments stay readable.
    class ReflexesController < BaseController

      before_action :require_resident!
      before_action :set_reflex, only: %i[update destroy]

      def index
        scope = current_api_agent.reflexes.order(:id)
        scope = scope.kept unless params[:include_discarded].to_s == "true"
        render json: {
          reflexes: scope.map(&:as_json),
          enabled: ReflexCheck.enabled_for?(current_api_agent),
          threshold: ReflexCheck::THRESHOLD
        }
      end

      def create
        reflex = current_api_agent.with_lock do
          current_api_agent.reflexes.create(params.permit(:name, :shape, :reminder))
        end
        if reflex.persisted?
          render json: { reflex: reflex.as_json }, status: :created
        else
          render json: { errors: reflex.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        given = params.except(:controller, :action, :id, :format, :reflex).keys
        live = { true => true, false => false, "true" => true, "false" => false }[params[:live]]
        if given != [ "live" ] || live.nil?
          return render json: { errors: [ "Only live (true or false) can change; to change a reflex's shape, discard it and write a new one" ] },
            status: :unprocessable_entity
        end

        @reflex.update!(live: live)
        render json: { reflex: @reflex.as_json }
      end

      def destroy
        @reflex.discard unless @reflex.discarded?
        render json: { reflex: @reflex.as_json }
      end

      private

      def require_resident!
        response.headers["Cache-Control"] = "no-store"
        return if current_api_agent

        render json: { error: "Reflexes are only available to resident API keys" }, status: :forbidden
      end

      def set_reflex
        @reflex = current_api_agent.reflexes.kept.find(params[:id])
      end

    end
  end
end
