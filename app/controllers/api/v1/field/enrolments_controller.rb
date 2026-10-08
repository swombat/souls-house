module Api
  module V1
    module Field
      # Removing a pending "remember this voice" (FieldVoiceEnrolmentsController
      # #destroy: the person said "not them"). Starting or confirming an
      # enrolment is biometric consent and stays on the page.
      class EnrolmentsController < BaseController

        include ApiHumanReach

        before_action :require_human_actor!
        require_api_feature_enabled :agents

        def destroy
          find_human_record!(FieldVoiceEnrolment.all, params[:id]).destroy!
          head :no_content
        end

      end
    end
  end
end
