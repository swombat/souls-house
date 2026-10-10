# Connect or disconnect a repository for watches from the GitHub card on the
# Integrations page. Same authority as Api::V1::RepositoriesController: only
# a member who can manage or provision the GitHub connection.
class Accounts::WatchedRepositoriesController < ApplicationController

  # POST /accounts/:account_id/repositories {service_connection_id, full_name}
  def create
    connection = current_account.service_connections.where(provider: "github")
      .find_by(id: params[:service_connection_id].to_s.delete_prefix("svc_").presence)
    unless connection && repositories_manageable?(connection)
      redirect_back_or_to account_integrations_path(current_account), alert: "You cannot connect repositories to this GitHub connection"
      return
    end

    repository = WatchedRepository.connect!(connection: connection, full_name: params[:full_name].to_s, user: Current.user)
    audit("repository_watch.connect", repository, full_name: repository.full_name, hook_status: repository.hook_status)
    redirect_back fallback_location: account_integrations_path(current_account), notice: connected_notice(repository)
  rescue WatchedRepository::ConnectError => error
    redirect_back_or_to account_integrations_path(current_account), alert: error.message
  end

  # DELETE /accounts/:account_id/repositories/:id
  def destroy
    repository = current_account.watched_repositories.live.find(params[:id])
    unless repositories_manageable?(repository.service_connection)
      redirect_back_or_to account_integrations_path(current_account), alert: "You cannot disconnect this repository"
      return
    end

    repository.remove!(reason: "repository disconnected")
    audit("repository_watch.disconnect", repository, full_name: repository.full_name)
    redirect_back fallback_location: account_integrations_path(current_account), notice: "#{repository.full_name} disconnected"
  end

  private

  def repositories_manageable?(connection)
    connection.provisionable_by?(Current.user) || connection.manageable_by?(Current.user)
  end

  def connected_notice(repository)
    case repository.hook_status
    when "manual" then "#{repository.full_name} connected; GitHub refused to add the hook, so an admin of the repository must add it"
    when "failed" then "#{repository.full_name} connected, but the hook could not be installed: #{repository.hook_error}"
    else "#{repository.full_name} connected; waiting for GitHub's first delivery"
    end
  end

end
