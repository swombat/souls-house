module Api
  module V1
    # A person's own device streams in the key's account, as on the web
    # (DeviceStreamsController). Only the stream's subject reaches a stream;
    # everyone else gets 404. Resident keys are refused.
    #
    # Two levels, mirroring the web's two sets of routes:
    #
    # - Managing (create, change readers and ingestion, issue a credential)
    #   needs the person to be a confirmed member of the account now. Like the
    #   web, there's no site-admin bypass: these are the subject's own controls.
    # - Recovery (list, read, revoke a credential, delete a session, delete
    #   and close the stream) stays open to the subject after they leave the
    #   account, so they can always revoke devices and delete their data.
    #
    # A key reaches only streams in its own account. The web's personal page
    # also lists streams in the person's other accounts; a key pinned to one
    # account doesn't.
    class DeviceStreamsController < BaseController

      include ApiHumanKey

      before_action :require_human_key!
      before_action -> { response.headers["Cache-Control"] = "no-store" }
      before_action :require_confirmed_member!, only: %i[create update credential]
      before_action :find_owned_stream, except: %i[index create]

      rescue_from DeviceStream::Rejected do |error|
        render json: { error: error.message }, status: error.status
      end

      rescue_from ActiveRecord::RecordInvalid do |error|
        render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

      def index
        streams = owned_streams.order(created_at: :desc)
        render json: { device_streams: streams.map { |stream| summary_json(stream) } }
      end

      def show
        render json: { device_stream: detail_json(@stream) }
      end

      # Starts disabled with no readers other than the subject, as on the web.
      def create
        stream = DeviceStream.create!(account: current_api_account, subject_user: current_api_user,
          name: params[:name], enabled: false)
        render json: { device_stream: detail_json(stream) }, status: :created
      end

      # Readers and ingestion. Each of reader_user_ids, reader_agent_ids and
      # enabled is optional; one left out keeps its current value.
      def update
        user_ids = params.key?(:reader_user_ids) ? decode_ids(User, params[:reader_user_ids]) : @stream.reader_user_ids
        agent_ids = params.key?(:reader_agent_ids) ? decode_ids(Agent, params[:reader_agent_ids]) : @stream.reader_agent_ids
        enabled = params.key?(:enabled) ? ActiveModel::Type::Boolean.new.cast(params[:enabled]) == true : @stream.enabled?

        @stream.configure!(user_ids:, agent_ids:, enabled:)
        render json: { device_stream: detail_json(@stream.reload) }
      end

      # The append-only device token. Shown once, here; it can't be read again.
      def credential
        token = @stream.issue_credential!
        render json: {
          credential: {
            token: token,
            ingest_url: "#{request.base_url}/api/v1/streams/#{@stream.stream_key}/samples"
          },
          note: "Copy this to the device now; it won't be shown again. It can only append samples to this stream."
        }, status: :created
      end

      def revoke
        @stream.revoke_credential!(params[:credential_id])
        head :no_content
      end

      # Hides the session from every reader and device; the samples stay stored.
      def erase_session
        @stream.erase_session!(params[:session_id])
        head :no_content
      end

      # Hides every session, revokes every device and closes the stream for
      # good. Nothing is removed from storage.
      def destroy
        @stream.erase!
        head :no_content
      end

      private

      def require_confirmed_member!
        return if current_api_user.confirmed_accounts.exists?(id: current_api_account.id)

        render json: { error: "Not found" }, status: :not_found
      end

      def owned_streams
        DeviceStream.where(subject_user: current_api_user, account: current_api_account)
      end

      def find_owned_stream
        @stream = owned_streams.find_by!(stream_key: params[:id])
      end

      def decode_ids(model, ids)
        Array(ids).reject(&:blank?).map { |id| model.decode_id(id) }
      end

      def summary_json(stream)
        {
          id: stream.stream_key,
          stream_key: stream.stream_key,
          name: stream.name,
          account: { id: stream.account.to_param, name: stream.account.name },
          enabled: stream.enabled?,
          erased_at: stream.erased_at&.iso8601,
          created_at: stream.created_at.iso8601
        }
      end

      # What the controls page shows: readers, devices (never their tokens) and
      # the newest 100 sessions. Reader choices are offered only to a current
      # member, as on the page.
      def detail_json(stream)
        manageable = current_api_user.confirmed_accounts.exists?(id: stream.account_id)
        summary_json(stream).merge(
          manageable: manageable,
          reader_user_ids: stream.reader_user_ids.map { |id| User.encode_id(id) },
          reader_agent_ids: stream.reader_agent_ids.map { |id| Agent.encode_id(id) },
          reader_options: (reader_options_json(stream) if manageable && !stream.erased_at?),
          batches_count: stream.batches_count,
          credentials: stream.device_stream_credentials.order(created_at: :desc).map do |credential|
            { id: credential.to_param, created_at: credential.created_at.iso8601, revoked_at: credential.revoked_at&.iso8601 }
          end,
          sessions: stream.device_stream_sessions.order(created_at: :desc).limit(100).map do |session|
            { session_id: session.session_uuid, created_at: session.created_at.iso8601, erased_at: session.erased_at&.iso8601 }
          end
        )
      end

      def reader_options_json(stream)
        {
          users: stream.account.memberships.where.not(confirmed_at: nil).includes(:user).map(&:user).map do |user|
            { id: user.to_param, name: user.display_name }
          end,
          agents: stream.account.agents.order(:name).map { |agent| { id: agent.to_param, name: agent.name } }
        }
      end

    end
  end
end
