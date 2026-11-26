module Api
  module V1
    module Visiting
      class QuietReasonsController < BaseController

        before_action :authenticate_visit!

        def create
          chat = seated_chat!
          wake = wake_for(chat) || raise(ActiveRecord::RecordNotFound)
          wake.interaction.record_quiet_reason!(params[:reason])
          render json: { ok: true }, status: :created
        rescue AgentRuntimeInteraction::QuietReasonRefused => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

      end
    end
  end
end
