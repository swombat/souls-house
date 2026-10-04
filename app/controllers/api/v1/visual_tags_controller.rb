module Api
  module V1
    class VisualTagsController < BaseController

      def index
        render json: { visual_tags: requested_account.visual_tags.palette_order.map(&:as_json) }
      end

    end
  end
end
