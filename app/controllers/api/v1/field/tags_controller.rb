module Api
  module V1
    module Field
      # The account's tags. Anyone may list them. Renaming or deleting a tag
      # changes every item that carries it, including other people's, so it
      # is a person's act (any member of the tag's account), never a
      # resident's. Residents add and remove tags on items
      # (ItemTagsController), and can't make a tag vanish from items they
      # didn't tag.
      #
      # Rename onto a name that's already a tag: 409, unless merge: true, which
      # moves this tag's items onto the existing one. Delete discards: the tag
      # leaves every item and the row is kept.
      class TagsController < BaseController

        include ApiHumanReach
        include ApiHomeAccountOnly

        before_action :require_human_actor!, only: %i[update destroy]
        require_api_feature_enabled :agents, unless: -> { current_api_agent }

        def index
          account = current_api_agent ? current_api_account : human_request_account!
          counts = FieldTag.item_counts(account)
          tags = account.field_tags.kept.by_name
          render json: { tags: tags.map { |tag| { id: tag.to_param, name: tag.name, item_count: counts.fetch(tag.id, 0) } } }
        end

        def update
          tag = find_human_record!(FieldTag.kept, params[:id])
          name = params[:name]
          return render json: { error: "Provide name" }, status: :unprocessable_entity unless name.is_a?(String)

          merge = ActiveModel::Type::Boolean.new.cast(params[:merge]) == true
          result = tag.rename!(name, by: current_api_user, merge: merge)
          render json: { tag: { id: result.to_param, name: result.name, merged: result != tag } }
        rescue FieldTag::Conflict => e
          render json: {
            error: "#{e.message}. Send merge: true to move this tag's items onto it.",
            existing: { id: e.existing.to_param, name: e.existing.name }
          }, status: :conflict
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
        end

        def destroy
          find_human_record!(FieldTag.kept, params[:id]).discard_by!(current_api_user)
          head :no_content
        end

      end
    end
  end
end
