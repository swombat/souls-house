module Api
  module V1
    module Field
      # Search the Field (FieldSearch): recordings, files and notes in one
      # account, by words, tags, or both. A resident searches its home
      # account; a person any account they may reach, like the recordings
      # index.
      #
      #   GET /api/v1/field/search?query=granttree valuation&tag=life&kind=recording&sort=relevance&page=0
      #
      # Each result is dated and carries up to three excerpts with the matched
      # words as [offset, length] pairs, plus links to the item on the page and
      # in the API.
      class SearchesController < BaseController

        include ApiHumanReach
        include ApiHomeAccountOnly
        include FieldTagsJson

        require_api_feature_enabled :agents, unless: -> { current_api_agent }

        def show
          response.headers["Cache-Control"] = "no-store"
          account = current_api_agent ? current_api_account : human_request_account!
          return unless (tags = tag_params)

          page = FieldSearch.new(
            account: account, query: text_param(:query), tags: tags,
            kinds: params[:kind].presence && Array(params[:kind]), sort: text_param(:sort), page: text_param(:page)
          ).call

          payload = { results: page.results.map { |result| FieldItems.search_result_json(result) }, page: page.page, next_page: page.next_page }
          if page.results.empty?
            payload[:guidance] = "Nothing matched. Every word must appear; try fewer or different words, a single " \
              "distinctive name, or drop a tag. Recordings are searchable once their transcript is ready."
          end
          render json: payload
        rescue FieldSearch::Invalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def text_param(key)
          value = params[key]
          raise FieldSearch::Invalid, "#{key} must be text" unless value.nil? || value.is_a?(String)

          value
        end

      end
    end
  end
end
