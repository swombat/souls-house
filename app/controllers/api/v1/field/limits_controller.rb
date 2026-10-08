module Api
  module V1
    module Field
      # What the Field page tells a person before they upload: the rolling
      # recording allowance and the size limits (FieldController#index props).
      class LimitsController < BaseController

        include ApiHumanReach

        before_action :require_human_actor!
        require_api_feature_enabled :agents

        def show
          render json: {
            recording_allowance: FieldItems.allowance_json(human_request_account!),
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
