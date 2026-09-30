class Admin::JobsController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin

  AVAILABLE_JOBS = {
    "cleanup_orphaned_messages" => {
      job_class: CleanupOrphanedMessagesJob,
      name: "Cleanup Orphaned Messages",
      description: "Removes assistant messages that were never properly finalized (from failed streaming retries or tool call splits)."
    },
    "hosted_agent_runtime_reconcile" => {
      job_class: HostedAgentRuntimeReconcileJob,
      name: "Reconcile Hosted Resident Runtime",
      description: "Recreates hosted resident sandbox containers whose runtime image is stale, preserving identity and Chaos volumes."
    }
  }.freeze

  def index
    render inertia: "admin/jobs", props: {
      jobs: AVAILABLE_JOBS.map { |key, config|
        { key: key, name: config[:name], description: config[:description] }
      }
    }
  end

  def create
    key = params[:job_key]
    config = AVAILABLE_JOBS[key]

    unless config
      redirect_to admin_jobs_path, alert: "Unknown job: #{key}"
      return
    end

    config[:job_class].perform_later
    redirect_to admin_jobs_path, notice: "#{config[:name]} has been queued."
  end

  private

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end
