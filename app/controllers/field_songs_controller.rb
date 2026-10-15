# Songs in the Field, from the page: add, edit, delete, and the lookup the
# Add dialog uses for a title from a link and candidate lyrics.
class FieldSongsController < ApplicationController

  include FieldSongParams

  require_feature_enabled :agents
  before_action :set_field_song, only: %i[show update destroy]
  rate_limit to: 30, within: 1.minute, only: :lookup,
             with: -> { render json: { error: "Too many lookups; try again in a minute." }, status: :too_many_requests }

  # A conversation's song card reads the current Field object, never a copy
  # saved into message history. Account membership and kept scope apply here
  # just as they do on the Field page.
  def show
    response.headers["Cache-Control"] = "private, no-store"
    render json: { song: FieldItems.song_json(@field_song) }
  end

  # Local-only preview and idempotent save for an outside conversation link.
  def offer
    response.headers["Cache-Control"] = "private, no-store"
    offer = FieldSong::Offer.new(account: current_account, url: params[:url])
    song = if request.post?
      offer.save!(title: params[:title], artist: params[:artist], by: Current.user)
    else
      offer.existing_song
    end
    render json: { link: offer.link, song: (FieldItems.song_json(song) if song),
                   created: request.post? && song.previously_new_record? }
  rescue FieldSong::Offer::InvalidLink => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def create
    source = song_source
    song = current_account.field_songs.new(added_by: Current.user)
    song.assign_attributes(field_song_attributes(source, account: current_account))
    attach_song_audio(song, source[:audio])

    if song.save
      redirect_to account_field_path(current_account, tab: "songs", item: "song-#{song.to_param}"),
        notice: song.lyrics_missing? ? "Shared. The lyrics can be added when you have them." : "Shared in the Field."
    else
      redirect_to account_field_path(current_account, tab: "songs"), inertia: { errors: { song: song.errors.full_messages.to_sentence } }
    end
  rescue FieldSongParams::Invalid => e
    redirect_to account_field_path(current_account, tab: "songs"), inertia: { errors: { song: e.message } }
  end

  def update
    source = song_source
    @field_song.assign_attributes(field_song_attributes(source, account: current_account))
    attach_song_audio(@field_song, source[:audio])
    item_path = account_field_path(current_account, tab: params[:tab].presence || "songs", item: "song-#{@field_song.to_param}")

    if @field_song.save
      redirect_to item_path
    else
      redirect_to item_path, inertia: { errors: { song: @field_song.errors.full_messages.to_sentence } }
    end
  rescue FieldSongParams::Invalid => e
    redirect_to account_field_path(current_account, tab: "songs", item: "song-#{@field_song.to_param}"),
      inertia: { errors: { song: e.message } }
  end

  def destroy
    @field_song.discard!
    respond_to do |format|
      format.json { head :no_content }
      format.html { redirect_to account_field_path(current_account, tab: "songs"), notice: "Deleted from the Field." }
    end
  end

  # GET ?url=…               a title and artist from the link
  # GET ?title=…&artist=…    candidate lyrics (duration_ms optional)
  # Suggestions only; nothing is saved.
  def lookup
    lookup = FieldSongLookup.new
    if params[:url].present?
      render json: { suggestion: lookup.from_link(params[:url].to_s) }
    else
      candidates = lookup.lyrics(title: params[:title].to_s, artist: params[:artist].to_s, duration_ms: params[:duration_ms].to_i)
      render json: { candidates: candidates.map(&:to_h) }
    end
  rescue FieldSongLookup::Unusable => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue FieldSongLookup::Failed => e
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def set_field_song
    @field_song = current_account.field_songs.kept.find(params[:id])
  end

  def song_source
    params.fetch(:field_song, ActionController::Parameters.new)
  end

end
