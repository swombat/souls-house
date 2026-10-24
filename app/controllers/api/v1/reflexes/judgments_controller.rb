module Api
  module V1
    module Reflexes
      # The judgments of one of the resident's own reflexes, newest first:
      # what the shadow week reads.
      class JudgmentsController < BaseController

        PAGE_SIZE = 100

        def index
          response.headers["Cache-Control"] = "no-store"
          unless current_api_agent
            return render json: { error: "Reflexes are only available to resident API keys" }, status: :forbidden
          end
          unless params[:cursor].nil? || (params[:cursor].is_a?(String) && params[:cursor].match?(/\A[a-zA-Z0-9]{1,100}\z/))
            return render json: { error: "Invalid cursor" }, status: :unprocessable_entity
          end

          reflex = current_api_agent.reflexes.find(params[:reflex_id])
          scope = reflex.judgments.includes(:reflex, message: :chat).order(id: :desc)
          scope = scope.where("reflex_judgments.id < ?", reflex.judgments.find(params[:cursor]).id) if params[:cursor].present?
          judgments = scope.limit(PAGE_SIZE + 1).to_a
          render json: {
            judgments: judgments.first(PAGE_SIZE).map(&:as_json),
            next_cursor: judgments.length > PAGE_SIZE ? judgments[PAGE_SIZE - 1].to_param : nil
          }
        end

      end
    end
  end
end
