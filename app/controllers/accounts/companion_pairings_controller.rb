# "Add a computer" on the Computers page: an owner or admin types the code a
# computer is showing, sees what it offers, picks residents and access, and
# approves. See CompanionPairing.
class Accounts::CompanionPairingsController < ApplicationController

  rate_limit to: 20, within: 10.minutes, only: :lookup,
    with: -> { render json: { error: "Too many tries. Wait a few minutes and try again." }, status: :too_many_requests }

  before_action :set_account
  before_action :require_admin!

  # JSON for the page: what the computer with this code is offering.
  def lookup
    pairing = CompanionPairing.find_pending_by_code(params[:code])
    unless pairing
      return render json: { error: "No computer is waiting with that code. Check it, or get a new one on the computer." },
        status: :not_found
    end

    render json: {
      name: pairing.name,
      expires_at: pairing.expires_at,
      volumes: pairing.offered_volumes,
      residents: @account.agents.order(:name).map { |agent| { id: agent.to_param, name: agent.name } }
    }
  end

  def create
    pairing = CompanionPairing.find_pending_by_code(params[:code])
    unless pairing
      return redirect_to account_companion_devices_path(@account),
        alert: "That code has expired or was already used. Get a new one on the computer."
    end

    ids = Array(params[:resident_ids]).select { |id| id.is_a?(String) }
    agents = ids.filter_map { |id| @account.agents.find_by(id: Agent.decode_id(id)) }
    agents = [] unless agents.size == ids.size && agents.all? { |agent| ids.include?(agent.to_param) }
    accesses = params[:accesses].respond_to?(:to_unsafe_h) ? params[:accesses].to_unsafe_h : {}
    pairing.approve!(account: @account, user: Current.user, agents: agents, accesses: accesses)
    redirect_to account_companion_devices_path(@account),
      notice: "#{pairing.name} is being added. It finishes on its own within a few seconds."
  rescue CompanionPairing::Invalid => error
    redirect_to account_companion_devices_path(@account), alert: error.message
  rescue Hashids::InputError, ActiveRecord::RecordInvalid
    redirect_to account_companion_devices_path(@account), alert: "That couldn't be approved"
  end

  private

  def admin?
    Current.user&.site_admin ||
      Current.user&.confirmed_memberships&.find_by(account: @account)&.admin? || false
  end

  def require_admin!
    return if admin?

    respond_to do |format|
      format.json { render json: { error: "Only an owner or admin of this account can add computers" }, status: :forbidden }
      format.any { redirect_to account_companion_devices_path(@account), alert: "Only an owner or admin of this account can add computers" }
    end
  end

  def set_account
    @account = find_current_user_account!(params[:account_id])
    Current.account = @account
  end

  def current_account
    @account || super
  end

end
