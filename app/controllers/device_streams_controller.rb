class DeviceStreamsController < ApplicationController

  before_action :set_stream_account
  before_action :find_owned_stream, except: [ :index, :create ]
  helper_method :stream_controls_path, :stream_index_path
  before_action -> { response.headers["Cache-Control"] = "no-store" }
  layout false

  rescue_from DeviceStream::Rejected, ActiveRecord::RecordInvalid do |error|
    render plain: error.message, status: :unprocessable_entity
  end

  def index
    @streams = DeviceStream.where(subject_user: Current.user).order(created_at: :desc)
    @streams = @streams.where(account: @stream_account) if @stream_account
    @streams = @streams.includes(:account)
  end

  def create
    @stream = DeviceStream.create!(account: @stream_account, subject_user: Current.user, name: params[:name], enabled: false)
    redirect_to stream_controls_path
  end

  def show
    @users = @stream_account ? @stream.account.memberships.where.not(confirmed_at: nil).includes(:user).map(&:user) : []
    @agents = @stream_account ? @stream.account.agents.order(:name) : []
    @sessions = @stream.device_stream_sessions.order(created_at: :desc).limit(100)
  end

  def update
    @stream.configure!(
      user_ids: Array(params[:reader_user_ids]).reject(&:blank?).map { |id| User.decode_id(id) },
      agent_ids: Array(params[:reader_agent_ids]).reject(&:blank?).map { |id| Agent.decode_id(id) },
      enabled: params[:enabled] == "1"
    )
    redirect_to stream_controls_path
  end

  def credential
    @raw_token = @stream.issue_credential!
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
