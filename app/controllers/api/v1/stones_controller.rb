module Api
  module V1
    class StonesController < BaseController

      before_action :set_chat
      before_action :set_stone, only: [ :show, :destroy ]

      rescue_from Stone::Conflict do |error|
        render json: { error: error.message }, status: :conflict
      end
      rescue_from Stone::Withdrawn do |error|
        render json: { error: error.message }, status: :gone
      end
      rescue_from Stone::InvalidInput do |error|
        render json: { error: error.message }, status: :unprocessable_entity
      end
      rescue_from Stone::Document::Invalid do |error|
        render json: { errors: error.errors }, status: :unprocessable_entity
      end
      rescue_from ActiveRecord::RecordInvalid do |error|
        render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
      end

      def index
        stones = @chat.stones.order(id: :desc).limit(100)
        render json: { stones: stones.map { |stone| stone_json(stone) } }
      end

      def create
        stone = Stone.publish!(
          chat: @chat, title: params[:title], html: submitted_html,
          author: current_api_agent || current_api_user, public: public_acknowledged?
        )
        render json: { stone: stone_json(stone) }, status: :created
      end

      def show
        render json: { stone: stone_json(@stone) }
      end

      def destroy
        @stone.withdraw!
        head :no_content
      end

      private

      def set_chat
        response.headers["Cache-Control"] = "no-store"
        scope = current_api_account.chats.kept
        if current_api_agent
          scope = scope.joins(:chat_agents).where(chat_agents: { agent_id: current_api_agent.id })
        end
        @chat = scope.find(params[:conversation_id])
      end

      def set_stone
        @stone = @chat.stones.find(params[:id])
      end

      def public_acknowledged?
        params[:public] == true || (request.media_type != "application/json" && params[:public] == "true")
      end

      def submitted_html
        text = params[:html]
        file = params[:file]
        if text.present? && file.present?
          raise Stone::InvalidInput, "Provide HTML text or one HTML file, not both"
        end
        return text if text.is_a?(String) && file.nil?

        unless text.nil? && file.is_a?(ActionDispatch::Http::UploadedFile) && File.extname(file.original_filename).downcase == ".html"
          raise Stone::InvalidInput, "Provide HTML text or one .html file"
        end
        raise Stone::InvalidInput, "HTML exceeds the 5 MiB limit" if file.size > Stone::MAX_HTML_BYTES

        file.read(Stone::MAX_HTML_BYTES + 1).force_encoding(Encoding::UTF_8)
      end

      def stone_json(stone)
        latest = stone.latest_revision
        {
          id: stone.to_param, withdrawn_at: stone.withdrawn_at&.iso8601,
          public_url: "/stones/#{stone.public_token}",
          latest_revision: latest && revision_json(latest),
          created_at: stone.created_at.iso8601
        }
      end

      def revision_json(revision)
        {
          id: revision.to_param, number: revision.number, title: revision.title,
          public_url: "/stones/#{revision.stone.public_token}/revisions/#{revision.number}",
          author: { type: revision.agent_id ? "agent" : "human", id: revision.author.to_param },
          policy_version: revision.policy_version, preview_status: revision.preview_status,
          preview_error: revision.preview_error, created_at: revision.created_at.iso8601
        }
      end

    end
  end
end
