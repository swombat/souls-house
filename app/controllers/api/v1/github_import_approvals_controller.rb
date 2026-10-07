class Api::V1::GithubImportApprovalsController < Api::V1::BaseController

  def show
    return head :forbidden unless current_api_agent&.github_resident_import
    request = current_api_agent.github_resident_import
    request.require_approval!
    render json: { approved: true, import_id: request.id.to_s,
      repository: request.repository, branch: request.branch,
      portable_home_id: request.portable_home_id, home_profile: "portable_v1",
      sync_strategy: request.sync_strategy, sync_configuration: request.sync_configuration,
      credential_fingerprint: request.approved_credential_fingerprint,
      commit_sha: request.approved_commit_sha }
  end

end
