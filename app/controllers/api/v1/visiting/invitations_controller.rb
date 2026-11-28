module Api
  module V1
    module Visiting
      # Before a visit: the invitation token is the only credential. Preview
      # shows whose account and until when; accepting mints the visit.
      class InvitationsController < BaseController

        def show
          invitation = VisitorInvitation.find_by_token(params[:token]) || raise(ActiveRecord::RecordNotFound)
          render json: invitation.preview_json
        end

        def accept
          invitation = VisitorInvitation.find_by_token(params[:token]) || raise(ActiveRecord::RecordNotFound)
          admission = invitation.accept!(
            name: params[:name], colour: params[:colour], icon: params[:icon],
            home_origin: params[:home_origin], home_name: params[:home_name]
          )
          render json: { visit_token: admission.raw_token, visit: admission.status_json }, status: :created
        rescue ArgumentError => error
          render json: { error: error.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => error
          render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
        end

      end
    end
  end
end
