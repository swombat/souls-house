# Owner-facing management of a resident's outgoing visits to other houses:
# previewing an invitation link, accepting it to mint a Visit with an encrypted
# visit_token, listing visits, and ending a visit.
class Agents::VisitsController < ApplicationController

  include AgentScoped

  before_action :require_account_owner!

  def index
    render json: { visits: @agent.visits.order(created_at: :desc).map(&:as_json) }
  end

  def preview
    link = Visits::InvitationLink.parse(params[:invitation_url], origin: params[:origin], token: params[:token])
    response = visit_client.preview_invitation(origin: link.origin, token: link.token)
    unless response.success? && response.json.is_a?(Hash)
      render json: { error: remote_error(response, "Couldn't read that invitation") }, status: remote_error_status(response)
      return
    end

    render json: {
      origin: link.origin,
      token: link.token,
      preview: response.json
    }
  rescue Visits::InvitationLink::InvalidError, Visits::Client::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def create
    link = Visits::InvitationLink.parse(params[:invitation_url], origin: params[:origin], token: params[:token])
    local_name = params[:local_name].to_s.strip.presence || @agent.name
    max_wakes = params[:max_wakes_per_hour].presence&.to_i || Visit::DEFAULT_MAX_WAKES_PER_HOUR

    response = visit_client.accept_invitation(
      origin: link.origin,
      token: link.token,
      name: local_name,
      colour: @agent.colour,
      icon: @agent.icon,
      home_origin: home_origin,
      home_name: home_name
    )
    unless response.success? && response.json.is_a?(Hash) && response.json["visit_token"].present?
      render json: { error: remote_error(response, "Couldn't accept that invitation") }, status: remote_error_status(response)
      return
    end

    remote_visit = response.json["visit"].is_a?(Hash) ? response.json["visit"] : {}
    visit = @agent.visits.create!(
      created_by: Current.user,
      visited_origin: link.origin,
      visited_house_name: remote_visit.dig("house", "name").presence || params[:visited_house_name].to_s.strip.presence,
      visited_account_name: remote_visit.dig("account", "name").presence || remote_visit["account_name"].presence,
      local_name: remote_visit.dig("agent", "name").presence || remote_visit["local_name"].presence || local_name,
      visit_token: response.json["visit_token"],
      max_wakes_per_hour: max_wakes
    )
    audit("start_resident_visit", @agent, visit_id: visit.to_param, visited_origin: visit.visited_origin)
    render json: { visit: visit.as_json }, status: :created
  rescue Visits::InvitationLink::InvalidError, Visits::Client::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def destroy
    visit = @agent.visits.find(params[:id])
    visit.leave!(client: visit_client)
    audit("end_resident_visit", @agent, visit_id: visit.to_param, visited_origin: visit.visited_origin)
    render json: { visit: visit.as_json }
  end

  private

  def visit_client
    @visit_client ||= Visits::Client.new
  end

  def home_origin
    raw = ENV["SOULSHOUSE_PUBLIC_URL"].presence || request.base_url
    Visits::Client.allow_private_origins? ? raw.sub(/\Ahttp:\/\//i, "https://") : raw
  end

  def home_name
    Setting.instance.site_name.presence || "this house"
  end

  def remote_error(response, fallback)
    return response.json["error"] if response.json.is_a?(Hash) && response.json["error"].present?

    "#{fallback} (visited house answered HTTP #{response.status})"
  end

  def remote_error_status(response)
    (400..499).cover?(response.status) ? :unprocessable_entity : :bad_gateway
  end

end
