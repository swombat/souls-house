class Api::V1::StreamsController < Api::V1::BaseController

  before_action :find_readable_stream

  def latest
    now = Time.current
    # Bound by observation time, not arrival order. A late retry cannot become "latest".
    batches = @stream.visible_batches
      .where(observed_at: (now - 20.minutes)..(now + 5.minutes))
      .includes(:device_stream_session).order(observed_at: :desc, id: :desc).limit(1201).to_a
    truncated = batches.length > 1200
    batches = batches.first(1200)
    render json: {
      schema: "rr.v1", stream_key: @stream.stream_key, server_time: now.iso8601(6),
      truncated: truncated, window_seconds: 1200,
      latest_received_at: batches.map(&:created_at).max&.iso8601(6),
      batches: batches.reverse.map { |batch|
        { session_id: batch.device_stream_session.session_uuid, sequence: batch.sequence,
          observed_at: batch.observed_at.iso8601(6), received_at: batch.created_at.iso8601(6), rr_ms: batch.rr_ms }
      }
    }
  end

  def sessions
    rows = @stream.device_stream_sessions.where(erased_at: nil)
      .joins(:device_stream_batches)
      .group("device_stream_sessions.id")
      .order(Arel.sql("MAX(device_stream_batches.observed_at) DESC, device_stream_sessions.id DESC"))
      .limit(51)
      .pluck("device_stream_sessions.session_uuid",
             Arel.sql("MIN(device_stream_batches.observed_at)"),
             Arel.sql("MAX(device_stream_batches.observed_at)"),
             Arel.sql("COUNT(device_stream_batches.id)"))
    render json: {
      stream_key: @stream.stream_key, server_time: Time.current.iso8601(6),
      truncated: rows.length > 50,
      sessions: rows.first(50).map { |uuid, first, last, count|
        { session_id: uuid, first_observed_at: first.iso8601(6),
          last_observed_at: last.iso8601(6), batch_count: count }
      }
    }
  end

  def show_session
    session = @stream.device_stream_sessions.find_by!(session_uuid: params[:session_id], erased_at: nil)
    cursor = params[:cursor]
    if params.key?(:cursor) && !(cursor.is_a?(String) && /\A(?:0|[1-9][0-9]{0,15})\z/.match?(cursor) && cursor.to_i <= 9_007_199_254_740_991)
      return render json: { error: "Invalid cursor" }, status: :unprocessable_entity
    end

    # Re-check the tombstone in the payload query itself: deletion only marks the
    # session, so a deletion committed after the lookup above must still hide rows.
    batches = @stream.visible_batches.where(device_stream_session_id: session.id).order(:sequence)
    batches = batches.where("sequence > ?", cursor.to_i) if cursor
    page = batches.limit(201).to_a
    more = page.length > 200
    page = page.first(200)
    render json: {
      schema: "rr.v1", stream_key: @stream.stream_key, session_id: session.session_uuid,
      server_time: Time.current.iso8601(6),
      next_cursor: more ? page.last.sequence.to_s : nil,
      batches: page.map { |batch|
        { session_id: session.session_uuid, sequence: batch.sequence,
          observed_at: batch.observed_at.iso8601(6), received_at: batch.created_at.iso8601(6), rr_ms: batch.rr_ms }
      }
    }
  end

  private

  def find_readable_stream
    response.headers["Cache-Control"] = "no-store"
    @stream = DeviceStream.find_by!(account: current_api_account, stream_key: params[:stream_key])
    raise ActiveRecord::RecordNotFound unless @stream.readable_by?(user: current_api_user, agent: current_api_agent)
  end

end
