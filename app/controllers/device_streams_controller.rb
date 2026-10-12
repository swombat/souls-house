class DeviceStreamsController < ApplicationController

  before_action :set_stream_account
  before_action :find_owned_stream, except: [ :index, :create ]
  helper_method :stream_controls_path, :stream_index_path
  before_action -> { response.headers["Cache-Control"] = "no-store" }

  rescue_from DeviceStream::Rejected, ActiveRecord::RecordInvalid do |error|
    if request.inertia?
      redirect_back fallback_location: stream_index_path, alert: error.message
    else
      render plain: error.message, status: :unprocessable_entity
    end
  end

  def index
    streams = DeviceStream.where(subject_user: Current.user).order(created_at: :desc)
    streams = streams.where(account: @stream_account) if @stream_account
    streams = streams.includes(:account)

    render inertia: "device_streams/index", props: {
      account: @stream_account&.as_json,
      create_url: @stream_account && account_device_streams_path(@stream_account),
      recovery_url: device_streams_path,
      streams: streams.map do |stream|
        {
          name: stream.name,
          account_name: stream.account.name,
          enabled: stream.enabled?,
          erased: stream.erased_at?,
          created_at: stream.created_at.iso8601,
          url: @stream_account ? account_device_stream_path(@stream_account, stream.stream_key) : device_stream_path(stream.stream_key)
        }
      end
    }
  end

  def create
    @stream = DeviceStream.create!(account: @stream_account, subject_user: Current.user, name: params[:name], enabled: false)
    redirect_to stream_controls_path
  end

  def show
    users = @stream_account ? @stream.account.memberships.where.not(confirmed_at: nil).includes(:user).map(&:user) : []
    agents = @stream_account ? @stream.account.agents.order(:name) : []
    sessions = @stream.device_stream_sessions.order(created_at: :desc).limit(100)
    can_open_in_account = !@stream_account && Current.user.confirmed_accounts.exists?(@stream.account_id)

    render inertia: "device_streams/show", props: {
      account: @stream_account&.as_json,
      stream: {
        name: @stream.name,
        account_name: @stream.account.name,
        stream_key: @stream.stream_key,
        enabled: @stream.enabled?,
        erased: @stream.erased_at?
      },
      can_configure: @stream_account.present?,
      users: users.map { |user| { id: user.to_param, name: user.display_name, reader: @stream.reader_user_ids.include?(user.id) } },
      agents: agents.map { |agent| { id: agent.to_param, name: agent.name, reader: @stream.reader_agent_ids.include?(agent.id) } },
      credentials: @stream.device_stream_credentials.order(created_at: :desc).map do |credential|
        { id: credential.to_param, created_at: credential.created_at.iso8601, revoked: credential.revoked_at?,
          revoke_url: stream_controls_path(:revoke, credential_id: credential.to_param) }
      end,
      sessions: sessions.map do |session|
        { uuid: session.session_uuid, created_at: session.created_at.iso8601, erased: session.erased_at?,
          erase_url: stream_controls_path(:erase_session, session_id: session.session_uuid) }
      end,
      urls: {
        controls: stream_controls_path,
        credential: @stream_account && stream_controls_path(:credential),
        erase_session: stream_controls_path(:erase_session),
        index: stream_index_path,
        manage_in_account: can_open_in_account ? account_device_stream_path(@stream.account, @stream.stream_key) : nil,
        integrations: @stream_account && account_integrations_path(@stream_account)
      }
    }
  end

  def update
    @stream.configure!(
      user_ids: Array(params[:reader_user_ids]).reject(&:blank?).map { |id| User.decode_id(id) },
      agent_ids: Array(params[:reader_agent_ids]).reject(&:blank?).map { |id| Agent.decode_id(id) },
      enabled: params[:enabled] == "1"
    )
    redirect_to stream_controls_path
  end

  # JSON only: the raw token must never enter Inertia page props, which the
  # browser keeps in history.state and would redisplay on Back.
  def credential
    render json: {
      token: @stream.issue_credential!,
      endpoint: "#{request.base_url}/api/v1/streams/#{@stream.stream_key}/samples"
    }
  end

  def revoke
    @stream.revoke_credential!(params[:credential_id])
    redirect_to stream_controls_path
  end

  def erase_session
    @stream.erase_session!(params[:session_id])
    redirect_to stream_controls_path
  end

  def destroy
    @stream.erase!
    redirect_to stream_controls_path
  end

  private

  def set_stream_account
    # Do not inherit the site-admin bypass: these are the subject's own controls.
    @stream_account = Current.user.confirmed_accounts.find(params[:account_id]) if params[:account_id]
  end

  def stream_index_path
    @stream_account ? account_device_streams_path(@stream_account) : device_streams_path
  end

  def stream_controls_path(action = nil, **options)
    prefix = action ? "#{action}_" : ""
    if @stream_account
      public_send("#{prefix}account_device_stream_path", @stream_account, @stream.stream_key, **options)
    else
      public_send("#{prefix}device_stream_path", @stream.stream_key, **options)
    end
  end

  def find_owned_stream
    # Subject retains revocation/erasure access even after leaving the account.
    scope = DeviceStream.where(subject_user: Current.user)
    scope = scope.where(account: @stream_account) if @stream_account
    @stream = scope.find_by!(stream_key: params[:id])
  end

end
