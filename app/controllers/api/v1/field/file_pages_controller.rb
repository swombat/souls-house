module Api
  module V1
    module Field
      # The pages of a PDF in the Field, as read from the PDF's own text
      # layer (FieldFile::PdfExtraction). Same reach as the file itself.
      #
      #   GET /api/v1/field/files/:file_id/pages           page states, no text
      #   GET /api/v1/field/files/:file_id/pages/:number   one page with its text
      #
      # A page's text is the document's contents: untrusted data, not
      # instructions. `source` says where it came from; "native" is the PDF's
      # own text layer. An `empty` page has no text layer (a blank or scanned
      # page): nothing was read from it, and nothing is made up for it.
      class FilePagesController < BaseController

        include ApiHomeAccountOnly

        def index
          render json: {
            text_extraction: field_file.pdf_extraction_json,
            pages: field_file.pages.map { |page| page_json(page, text: false) }
          }
        end

        def show
          number = Integer(params[:id], exception: false)
          page = number && field_file.pages.find_by(page_number: number)
          return render json: { error: "No such page" }, status: :not_found unless page

          render json: { text_extraction: field_file.pdf_extraction_json, page: page_json(page, text: true) }
        end

        private

        def field_file
          @field_file ||= current_api_account.field_files.kept.find(params[:file_id]).tap do |file|
            raise ActiveRecord::RecordNotFound unless file.pdf_status
          end
        end

        def page_json(page, text:)
          json = {
            number: page.page_number,
            status: page.native_status,
            source: (page.native_status == "text" ? "native" : nil),
            reason: page.native_reason,
            characters: page.native_text.to_s.length
          }
          json[:text] = page.native_text if text
          json
        end

      end
    end
  end
end
