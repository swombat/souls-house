module Api
  module V1
    # The account's transcription glossary (GET/POST/PATCH/DELETE
    # /api/v1/transcription_glossary), as on the web's glossary page. Terms
    # are named by `term`. A person acts in the selected account where they
    # are a confirmed member; a resident acts only in its home account, never
    # in an account where it is a guest.
    class TranscriptionGlossariesController < BaseController

      include TranscriptionGlossaryActions

      before_action :set_glossary_account
      before_action :require_term, only: %i[create update destroy]

      def show
        render json: { account_id: @account.to_param, **glossary_payload(@account) }
      end

      def create
        term = TranscriptionGlossary.new(@account).add!(glossary_term_param, by: actor, pinned: glossary_pinned_param || false)
        audit("add_transcription_glossary_term", term)
        render json: { term: term.as_json }, status: :created
      rescue ActiveRecord::RecordInvalid => error
        render_invalid(error.record)
      end

      def update
        unless params.key?(:pinned)
          return render json: { error: "Provide pinned (true or false)" }, status: :unprocessable_entity
        end

        term = pin_glossary_term!(@account, glossary_term_param, pinned: glossary_pinned_param || false, by: actor)
        audit("pin_transcription_glossary_term", term, pinned: term.pinned)
        render json: { term: term.as_json }
      rescue ActiveRecord::RecordInvalid => error
        render_invalid(error.record)
      end

      def destroy
        term = TranscriptionGlossary.new(@account).remove!(glossary_term_param, by: actor)
        audit("remove_transcription_glossary_term", term)
        render json: { removed: term.as_json.merge(removed_at: term.suppressed_at) }
      rescue ActiveRecord::RecordInvalid => error
        render_invalid(error.record)
      end

      private

      def set_glossary_account
        @account = if current_api_agent
          raise ActiveRecord::RecordNotFound if params[:account_id].present? && params[:account_id] != current_api_account.to_param

          current_api_account
        else
          human_account!(requested_account)
        end
      end

      def require_term
        return if glossary_term_param.present?

        render json: { error: "Provide term" }, status: :unprocessable_entity
      end

      def actor
        current_api_agent || current_api_user
      end

      def audit(action, record, **data)
        return if current_api_agent

        audit_human_action(action, record, account: @account, term: record.term, **data)
      end

      def render_invalid(record)
        render json: { error: record.errors.full_messages.to_sentence.presence || "Invalid", errors: record.errors.to_hash },
               status: :unprocessable_entity
      end

    end
  end
end
