module Api
  module V1
    module Visiting
      class WakesController < BaseController

        before_action :authenticate_visit!

        # Claim pending wakes (leased). Only wakes in conversations the
        # visitor is still seated in are handed out; the rest end now.
        def index
          wakes = VisitorWake.claim_for!(current_admission)
          live, gone = wakes.partition { |wake| current_admission.seated_in?(wake.chat) && wake.chat.respondable? }
          gone.each(&:expire!)
          render json: { wakes: live.map(&:as_json) }
        end

        def complete
          wake = current_admission.visitor_wakes.find(VisitorWake.decode_id(params[:id]))
          wake.complete!
          render json: wake.reload.as_json
        end

      end
    end
  end
end
