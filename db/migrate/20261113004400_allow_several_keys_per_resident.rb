class AllowSeveralKeysPerResident < ActiveRecord::Migration[8.0]

  # A resident had exactly one key (its container's). Named keys for its
  # bodies outside the house need more than one row per agent, so the unique
  # partial index becomes a plain one. Which key is the container's is still
  # recorded once, on agents.outbound_api_key_id.
  def up
    remove_index :api_keys, name: "index_api_keys_on_agent_id"
    add_index :api_keys, :agent_id, name: "index_api_keys_on_agent_id", where: "agent_id IS NOT NULL"
  end

  def down
    remove_index :api_keys, name: "index_api_keys_on_agent_id"
    add_index :api_keys, :agent_id, name: "index_api_keys_on_agent_id", unique: true, where: "agent_id IS NOT NULL"
  end

end
