module Api
  module App
    module V1
      # The signed-in device itself: who am I, and sign this device out.
      class SessionsController < BaseController

        def show
          render json: {
            user: { id: current_user.to_param, email_address: current_user.email_address },
            session: { id: current_app_session.to_param, device_label: current_app_session.device_label }
          }
        end

        def destroy
          current_app_session.revoke!(:logout)
          head :no_content
        end

      end
    end
  end
end
