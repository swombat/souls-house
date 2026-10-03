module Api
  module V1
    class StoneRevisionsController < StonesController

      skip_before_action :set_stone
      before_action :set_parent_stone

      def index
        render json: { revisions: @stone.stone_revisions.order(number: :desc).limit(100).map { |revision| revision_json(revision) } }
      end

      def show
        raise Stone::Withdrawn, "Stone has been withdrawn" if @stone.withdrawn?

        revision = @stone.stone_revisions.find(params[:id])
        render json: { revision: revision_json(revision).merge(html: revision.html_document) }
      end

      def create
        revision = @stone.revise!(
          title: params[:title], html: submitted_html, author: current_api_agent || current_api_user,
          public: public_acknowledged?, base_revision_id: params[:base_revision_id]
        )
        render json: {
          revision: revision_json(revision),
          notice: "Earlier revisions remain public. Withdraw the whole stone to remove them."
        }, status: :created
      end

      private

      def set_parent_stone
        @stone = @chat.stones.find(params[:stone_id])
      end

    end
  end
end
