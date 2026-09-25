class DeviceStreamsController < ApplicationController

  before_action :find_owned_stream, except: [ :index, :create ]
  before_action -> { response.headers["Cache-Control"] = "no-store" }
  layout false

  rescue_from DeviceStream::Rejected, ActiveRecord::RecordInvalid do |error|
    render plain: error.message, status: :unprocessable_entity
  end

  def index
    @streams = DeviceStream.where(subject_user: Current.user).order(created_at: :desc)
    @accounts = Current.user.confirmed_accounts
  end

  def create
    @current_account = Current.user.confirmed_accounts.find(params[:account_id])
    unless current_account&.memberships&.where(user: Current.user)&.where.not(confirmed_at: nil)&.exists?
      return head :forbidden
    end
    @stream = DeviceStream.create!(account: current_account, subject_user: Current.user, name: params[:name], enabled: false)
    redirect_to device_stream_path(@stream.stream_key)
  end

  def show
    @users = @stream.account.memberships.where.not(confirmed_at: nil).includes(:user).map(&:user)
    @agents = @stream.account.agents.order(:name)
    @sessions = @stream.device_stream_sessions.order(created_at: :desc).limit(100)
  end

  def update
    @stream.configure!(
      user_ids: Array(params[:reader_user_ids]).reject(&:blank?).map { |id| User.decode_id(id) },
      agent_ids: Array(params[:reader_agent_ids]).reject(&:blank?).map { |id| Agent.decode_id(id) },
      enabled: params[:enabled] == "1"
    )
    redirect_to device_stream_path(@stream.stream_key)
  end

  def credential
    @raw_token = @stream.issue_credential!
  end

  def revoke
    @stream.revoke_credential!(params[:credential_id])
    redirect_to device_stream_path(@stream.stream_key)
  end

  def erase_session
    @stream.erase_session!(params[:session_id])
    redirect_to device_stream_path(@stream.stream_key)
  end

  def destroy
    @stream.erase!
    redirect_to device_stream_path(@stream.stream_key)
  end

  private

  def find_owned_stream
    # Subject retains revocation/erasure access even after leaving the account.
    @stream = DeviceStream.find_by!(stream_key: params[:id], subject_user: Current.user)
  end

end
