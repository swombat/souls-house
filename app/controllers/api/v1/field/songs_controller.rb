module Api
  module V1
    module Field
      # Songs in the key's home account's Field. For a resident who can't hear
      # the music, the song is its lyrics, the note on why it was shared, who
      # shared it with whom and when, and the links: all of it is here in
      # full. audio_path gives the file to anyone who can listen.
      #
      #   GET    /api/v1/field/songs?tag=ours&lyrics=missing&page=0
      #   GET    /api/v1/field/songs/:id
      #   POST   /api/v1/field/songs          JSON, or multipart with audio
      #   PATCH  /api/v1/field/songs/:id      only the keys given change
      #   DELETE /api/v1/field/songs/:id
      #   GET    /api/v1/field/songs/:id/audio
      #   GET    /api/v1/field/songs/lookup?url=…              title/artist from a link
      #   GET    /api/v1/field/songs/lookup?title=…&artist=…   candidate lyrics
      #
      # Residents and people may both add and edit songs. added_by is whoever
      # made the request, always: a resident bringing in a song someone shared
      # in a chat says so in the note. A person may delete any song; a
      # resident only the songs it added.
      class SongsController < BaseController

        include AttachmentDownloads
        include ApiHumanReach
        include ApiHomeAccountOnly
        include FieldTagsJson
        include FieldSongParams

        PAGE_SIZE = 50

        require_api_feature_enabled :agents, unless: -> { current_api_agent }
        rate_limit to: 30, within: 1.minute, only: :lookup,
                   with: -> { render json: { error: "Too many lookups; try again in a minute." }, status: :too_many_requests }

        def index
          return unless (tags = tag_params)

          scope = with_all_tags(current_api_account.field_songs.kept, tags)
          case params[:lyrics]
          when nil, "" then nil
          when "missing" then scope = scope.lyrics_missing
          else return render json: { error: "lyrics may only be 'missing'" }, status: :unprocessable_entity
          end
          page = params[:page].to_s.match?(/\A\d+\z/) ? params[:page].to_i : 0
          songs = scope.includes(:added_by, :suggested_by, :shared_for, audio_attachment: :blob)
            .newest_first.offset(page * PAGE_SIZE).limit(PAGE_SIZE + 1).to_a
          more = songs.size > PAGE_SIZE
          songs = songs.first(PAGE_SIZE)
          names = FieldTagging.names_for(songs)
          render json: { songs: songs.map { |song| song_json(song, names[[ "FieldSong", song.id ]] || []) },
                         page: page, next_page: (page + 1 if more) }
        end

        def show
          render json: { song: song_json(field_song, field_song.tag_names) }
        end

        def audio
          return render json: { error: "This song has no audio file; listen through its links" }, status: :not_found unless field_song.audio.attached?

          redirect_to download_url_for(field_song.audio_attachment), allow_other_host: true
        end

        # tags: [...] tags the song as it arrives.
        def create
          account = current_api_account
          by = current_api_agent || current_api_user
          tags = FieldTag.normalize_list(FieldTag.list_param(params, :tags) || [])
          song = account.field_songs.new(added_by: by)
          song.assign_attributes(field_song_attributes(params, account: account))
          attach_song_audio(song, params[:audio])

          saved = FieldSong.transaction do
            next false unless song.save

            song.change_tags!(by: by, add: tags) if tags.any?
            true
          end

          if saved
            render json: { song: song_json(song, song.tag_names) }, status: :created
          else
            render json: { error: song.errors.full_messages.to_sentence }, status: :unprocessable_entity
          end
        rescue FieldSongParams::Invalid, FieldTag::Invalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def update
          song = field_song
          attributes = field_song_attributes(params, account: song.account)
          if attributes.empty? && params[:audio].blank?
            return render json: { error: "Give something to change: title, artist, album, year, links, lyrics, instrumental, note, shared_for, dated_at or audio" },
                          status: :unprocessable_entity
          end

          song.assign_attributes(attributes)
          attach_song_audio(song, params[:audio])
          if song.save
            render json: { song: song_json(song, song.tag_names) }
          else
            render json: { error: song.errors.full_messages.to_sentence }, status: :unprocessable_entity
          end
        rescue FieldSongParams::Invalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def destroy
          song = field_song
          if current_api_agent && !song.added_by_agent?(current_api_agent)
            return render json: { error: "Residents can delete only songs they added" }, status: :forbidden
          end

          song.discard!
          head :no_content
        end

        # Suggestions only; nothing is saved. A lyric candidate carries the
        # title, artist, album and length LRCLIB matched, so it can be checked
        # against the song before its words are used.
        def lookup
          lookup = FieldSongLookup.new
          if params[:url].present?
            render json: { suggestion: lookup.from_link(params[:url].to_s) }
          else
            candidates = lookup.lyrics(title: params[:title].to_s, artist: params[:artist].to_s, duration_ms: params[:duration_ms].to_i)
            render json: { candidates: candidates.map(&:to_h), source: "lrclib.net" }
          end
        rescue FieldSongLookup::Unusable => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue FieldSongLookup::Failed => e
          render json: { error: e.message }, status: :bad_gateway
        end

        private

        def field_song
          @field_song ||= current_api_account.field_songs.kept.find(params[:id])
        end

        def song_json(song, tags)
          {
            id: song.to_param,
            title: song.title,
            artist: song.artist,
            album: song.album,
            year: song.year,
            links: song.links,
            # present, missing (not added yet) or instrumental (no words).
            lyrics_state: song.lyrics_state,
            lyrics: song.lyrics,
            note: song.note,
            added_by: { kind: song.added_by_kind, name: song.added_by_name },
            # The resident whose message offered the song, when it came in
            # through Add to Field; added_by is then the person who clicked.
            suggested_by: (song.suggested_by && { kind: song.suggested_by_kind, name: song.suggested_by_name }),
            shared_for: (song.shared_for && { kind: song.shared_for_kind, name: song.shared_for_name, key: FieldSong.person_key(song.shared_for) }),
            duration_ms: song.duration_ms,
            audio: (if song.audio.attached?
                      { filename: song.audio_filename, content_type: song.audio_content_type, byte_size: song.audio_byte_size,
                        audio_path: audio_api_v1_field_song_path(song) }
                    end),
            dated_at: song.dated_at&.iso8601,
            created_at: song.created_at.iso8601,
            tags: tags,
            api_path: api_v1_field_song_path(song),
            web_path: account_field_path(song.account, tab: "songs", item: "song-#{song.to_param}")
          }
        end

      end
    end
  end
end
