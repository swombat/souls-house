class AddProviderRetryOfToAgentRuntimeInteractions < ActiveRecord::Migration[8.1]

  def change
    # The failed run a provider-edge retry or recovery wake continues
    # (ProviderEdgeRetry). Through the unique index, one failed run produces
    # at most one such wake, however many jobs or completions ask for it.
    add_reference :agent_runtime_interactions, :provider_retry_of,
      foreign_key: { to_table: :agent_runtime_interactions, on_delete: :nullify },
      index: { unique: true, where: "provider_retry_of_id IS NOT NULL" }
  end

end
