module Api
  module V1
    module Field
      # Files in the key's home account's Field. A resident who is a guest
      # elsewhere reads only its home Field, the same as whiteboards.
      class FilesController < BaseController

        include AttachmentDownloads
        include ApiHumanReach
        include ApiHomeAccountOnly
        include FieldTagsJson

        # Editing a file's title and note is the person's control on the
        # Field page (FieldFilesController#update): any member, any file, in
        # the file's own account.
        before_action :require_human_actor!, only: :update
        require_api_feature_enabled :agents, only: :update

        # tag=life (repeatable) keeps files carrying every one of those tags.
        def index
          return unless (tags = tag_params)

          files = with_all_tags(current_api_account.field_files.kept, tags)
            .includes(:uploaded_by, file_attachment: :blob).newest_first.to_a
          names = FieldTagging.names_for(files)
          render json: { files: files.map { |file| file_json(file, names[[ "FieldFile", file.id ]] || []) } }
        end

        def show
          render json: { file: file_json(field_file, field_file.tag_names) }
        end

        def download
          redirect_to download_url_for(field_file.file_attachment), allow_other_host: true
        end

        # tags: [...] (or tags[]=… in the multipart form) tags the file as it
        # arrives, e.g. with the folder an import came from.
        def create
          unless FieldFile::Upload.uploaded_file?(params[:file])
            return render json: { error: "file must be a multipart file upload" }, status: :unprocessable_entity
          end

          tags = FieldTag.normalize_list(FieldTag.list_param(params, :tags) || [])

          field_file = current_api_account.field_files.new(
            title: params[:title],
            note: params[:note],
            file: params[:file],
            uploaded_by: current_api_agent || current_api_user
          )

          saved = FieldFile.transaction do
            next false unless field_file.save

            field_file.change_tags!(by: field_file.uploaded_by, add: tags) if tags.any?
            true
          end

          if saved
            render json: { file: file_json(field_file, field_file.tag_names) }, status: :created
          else
            render json: { error: field_file.errors.full_messages.to_sentence }, status: :unprocessable_entity
          end
        rescue FieldTag::Invalid => e
          render json: { error: e.message }, status: :unprocessable_entity
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
          file = find_human_record!(FieldFile.kept, params[:id])
          attributes = params.permit(:title, :note)
          return render json: { error: "Provide title or note" }, status: :unprocessable_entity if attributes.empty?

          if file.update(attributes)
            render json: { file: file_json(file, file.tag_names) }
          else
            render json: { error: file.errors.full_messages.to_sentence }, status: :unprocessable_entity
          end
        end

        private

        def field_file
          @field_file ||= current_api_account.field_files.kept.find(params[:id])
        end

        def file_json(file, tags)
          {
            id: file.to_param,
            title: file.title,
            note: file.note,
            summary_short: file.summary_short,
            summary_long: file.summary_long,
            filename: file.filename,
            content_type: file.content_type,
            byte_size: file.byte_size,
            uploaded_by: { kind: file.uploader_kind, name: file.uploader_name },
            created_at: file.created_at.iso8601,
            tags: tags,
            download_path: download_api_v1_field_file_path(file)
          }
        end

      end
    end
  end
end
