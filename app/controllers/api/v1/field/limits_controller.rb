module Api
  module V1
    module Field
      # What the Field page tells a person before they upload: the rolling
      # recording allowance and the size limits (FieldController#index props).
      class LimitsController < BaseController

        include ApiHumanKey

        require_human_member
        require_api_feature_enabled :agents

        def show
          render json: {
            recording_allowance: FieldItems.allowance_json(current_api_account),
            max_recording_bytes: FieldRecording::MAX_BYTES,
            max_recording_label: FieldRecording::MAX_BYTES_LABEL,
            max_file_bytes: FieldFile::MAX_FILE_SIZE,
            max_file_label: FieldFile::MAX_FILE_SIZE_LABEL
          }
        end

      end
    end
  end
end
