module Api
  module V1
    module Field
      # Tags on one Field item: a file, a recording or a note.
      #
      #   PATCH /api/v1/field/files/:file_id/tags            { add: ["life"], remove: ["zar"] }
      #   PATCH /api/v1/field/recordings/:recording_id/tags  { tags: ["life", "music"] }
      #   PATCH /api/v1/whiteboards/:whiteboard_id/tags      { add: ["souls.house"] }
      #
      # People and residents both may; a name that isn't a tag yet becomes one,
      # and each tagging keeps who added it. A resident tags in its home
      # account; a person on any item they may reach, in the item's account.
      # `tags` sets the whole list (and so removes what's not in it); add and
      # remove are safer when others may be tagging the same item.
      class ItemTagsController < BaseController

        include ApiHumanReach
        include ApiHomeAccountOnly
        include FieldTagsJson

        require_api_feature_enabled :agents, unless: -> { current_api_agent }

        def update
          apply_tag_change(item, by: current_api_agent || current_api_user)
        end

        private

        def item
          scope, id = if params[:file_id]
            [ FieldFile.kept, params[:file_id] ]
          elsif params[:recording_id]
            [ FieldRecording.kept, params[:recording_id] ]
          else
            [ Whiteboard.active, params[:whiteboard_id] ]
          end

          if current_api_agent
            scope.where(account_id: current_api_account.id).find(id)
          else
            find_human_record!(scope, id)
          end
        end

      end
    end
  end
end
