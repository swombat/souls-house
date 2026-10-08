module Api
  module V1
    module Field
      # Files in the key's home account's Field. A resident who is a guest
      # elsewhere reads only its home Field, the same as whiteboards.
      class FilesController < BaseController

        include AttachmentDownloads
        include ApiHumanKey

        # Editing a file's title and note is the person's control on the
        # Field page (FieldFilesController#update): any member, any file.
        require_human_member only: :update
        require_api_feature_enabled :agents, only: :update

        def index
          files = current_api_account.field_files.kept.includes(:uploaded_by, file_attachment: :blob).newest_first
          render json: { files: files.map { |file| file_json(file) } }
        end

        def show
          render json: { file: file_json(field_file) }
        end

        def download
          redirect_to download_url_for(field_file.file_attachment), allow_other_host: true
        end

        def create
          unless FieldFile::Upload.uploaded_file?(params[:file])
            return render json: { error: "file must be a multipart file upload" }, status: :unprocessable_entity
          end

          field_file = current_api_account.field_files.new(
            title: params[:title],
            note: params[:note],
            file: params[:file],
            uploaded_by: current_api_agent || current_api_user
          )

          if field_file.save
            render json: { file: file_json(field_file) }, status: :created
          else
            render json: { error: field_file.errors.full_messages.to_sentence }, status: :unprocessable_entity
          end
        end

        def destroy
          file = field_file
          if current_api_agent && !file.uploaded_by_agent?(current_api_agent)
            return render json: { error: "Residents can delete only files they brought into the Field" }, status: :forbidden
          end

          file.discard!
          head :no_content
        end

        def update
          file = field_file
          attributes = params.permit(:title, :note)
          return render json: { error: "Provide title or note" }, status: :unprocessable_entity if attributes.empty?

          if file.update(attributes)
            render json: { file: file_json(file) }
          else
            render json: { error: file.errors.full_messages.to_sentence }, status: :unprocessable_entity
          end
        end

        private

        def field_file
          @field_file ||= current_api_account.field_files.kept.find(params[:id])
        end

        def file_json(file)
          {
            id: file.to_param,
            title: file.title,
            note: file.note,
            filename: file.filename,
            content_type: file.content_type,
            byte_size: file.byte_size,
            uploaded_by: { kind: file.uploader_kind, name: file.uploader_name },
            created_at: file.created_at.iso8601,
            download_path: download_api_v1_field_file_path(file)
          }
        end

      end
    end
  end
end
