module Api
  module V1
    module Field
      # Removing a pending "remember this voice" (FieldVoiceEnrolmentsController
      # #destroy: the person said "not them"). Starting or confirming an
      # enrolment is biometric consent and stays on the page.
      class EnrolmentsController < BaseController

        include ApiHumanKey

        require_human_member
        require_api_feature_enabled :agents

        def destroy
          current_api_account.field_voice_enrolments.find_by!(id: FieldVoiceEnrolment.decode_id(params[:id])).destroy!
          head :no_content
        end

      end
    end
  end
end
