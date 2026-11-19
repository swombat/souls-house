# "Add a computer" on the Computers page: any confirmed member of the account
# (Daniel, YMamQY JDbRxw: not only the owner) types the code a
# computer is showing, sees what it offers, picks residents and access, and
# approves. See CompanionPairing.
class Accounts::CompanionPairingsController < ApplicationController

  before_action :set_account
  before_action :require_member!

  # Looking a code up and approving one both search every pairing by code, so
  # they share one quota per person, counted after sign-in and the membership check.
  rate_limit to: 20, within: 10.minutes, only: %i[lookup create], store: RateLimitStore,
    scope: "companion-pairing-code", by: -> { "user:#{Current.user.id}" }, with: -> { too_many_tries }

  # JSON for the page: what the computer with this code is offering.
  def lookup
    pairing = CompanionPairing.find_pending_by_code(params[:code])
    unless pairing
      return render json: { error: "No computer is waiting with that code. Check it, or get a new one on the computer." },
        status: :not_found
    end

    render json: {
      id: pairing.to_param,
      code: params[:code],
      account_name: @account.name,
      name: pairing.name,
      expires_at: pairing.expires_at,
      volumes: pairing.offered_volumes,
      residents: @account.agents.order(:name).map { |agent| { id: agent.to_param, name: agent.name } }
    }
  end

  def create
    # The owner approves the offer they were shown: the code must still lead
    # to the same pairing the page looked up.
    pairing = CompanionPairing.find_pending_by_code(params[:code])
    unless pairing && params[:pairing_id].is_a?(String) && pairing.to_param == params[:pairing_id]
      return redirect_to account_companion_devices_path(@account),
        alert: "That code has expired, was already used, or now belongs to another computer. Get a new one on the computer."
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

  def too_many_tries
    message = "Too many tries. Wait a few minutes and try again."
    respond_to do |format|
      format.json { render json: { error: message }, status: :too_many_requests }
      format.any { redirect_to account_companion_devices_path(@account), alert: message }
    end
  end

  # Adding a computer offers that computer to the account's residents; the
  # person at it already chose what it offers. Any confirmed member may do it.
  # Changing or removing computers afterwards stays with owners and admins.
  def member?
    Current.user&.site_admin ||
      Current.user&.confirmed_memberships&.exists?(account: @account) || false
  end

  def require_member!
    return if member?

    respond_to do |format|
      format.json { render json: { error: "Only a member of this account can add computers" }, status: :forbidden }
      format.any { redirect_to account_companion_devices_path(@account), alert: "Only a member of this account can add computers" }
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
