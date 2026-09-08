class GithubIntegrationController < ApplicationController

  before_action :set_integration, except: %i[show create]

  def show
    integration = current_account.github_integration || current_account.build_github_integration

    render inertia: "settings/github_integration", props: {
      integration: integration_json(integration)
    }
  end

  def create
    state = SecureRandom.hex(32)
    session[:github_oauth_state] = state
    session[:github_oauth_state_expires_at] = 10.minutes.from_now.to_i

    integration = current_account.github_integration || current_account.create_github_integration!

    redirect_to integration.authorization_url(state: state, redirect_uri: github_redirect_uri),
                allow_other_host: true
  end

  def callback
    if params[:error]
      redirect_to github_integration_path, alert: "Authorization was denied"
      return
    end

    expected_state = session.delete(:github_oauth_state)
    expires_at = session.delete(:github_oauth_state_expires_at)

    unless expected_state == params[:state] && Time.current.to_i < expires_at.to_i
      redirect_to github_integration_path, alert: "Invalid or expired authorization"
      return
    end

    unless @integration
      redirect_to github_integration_path, alert: "No integration found"
      return
    end

    @integration.exchange_code!(code: params[:code], redirect_uri: github_redirect_uri)

    redirect_to select_repo_github_integration_path
  rescue GithubApi::Error => e
    redirect_to github_integration_path, alert: "Failed to connect: #{e.message}"
  end

  def select_repo
    unless @integration&.connected?
      redirect_to github_integration_path, alert: "Not connected to GitHub"
      return
    end

    repos = @integration.fetch_repos
    repos_list = (repos || []).map { |r| { full_name: r["full_name"], private: r["private"] } }

    render inertia: "settings/github_select_repo", props: {
      repos: repos_list,
      current_repo: @integration.repository_full_name
    }
  end

  def save_repo
    unless @integration&.connected?
      redirect_to github_integration_path, alert: "Not connected to GitHub"
      return
    end

    @integration.update!(repository_full_name: params[:repository_full_name])
    SyncGithubCommitsJob.perform_later(@integration.id)

    redirect_to github_integration_path, notice: "Repository linked successfully"
  end

  def update
    unless @integration
      redirect_to github_integration_path, alert: "No integration found"
      return
    end

    @integration.update!(integration_params)
    redirect_to github_integration_path, notice: "Settings updated"
  end

  def destroy
    @integration&.disconnect!

    redirect_to github_integration_path, notice: "GitHub disconnected"
  end

  def sync
    unless @integration&.ready_to_sync?
      redirect_to github_integration_path, alert: "No repository linked"
      return
    end

    SyncGithubCommitsJob.perform_later(@integration.id)
    redirect_to github_integration_path, notice: "Sync started"
  end

  private

  def set_integration
    @integration = current_account.github_integration
  end

  def github_redirect_uri
    base = Rails.configuration.x.public_url || request.base_url
    "#{base}/github_integration/callback"
  end

  def integration_params
    params.require(:github_integration).permit(:enabled)
  end

  def integration_json(integration)
    {
      id: integration.id,
      enabled: integration.enabled?,
      connected: integration.connected?,
      github_username: integration.github_username,
      repository_full_name: integration.repository_full_name,
      commits_synced_at: integration.commits_synced_at&.iso8601
    }
  end

end
