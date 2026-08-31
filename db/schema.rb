# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_31_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "accounts", force: :cascade do |t|
    t.integer "account_type", default: 0, null: false
    t.text "anthropic_api_key"
    t.datetime "created_at", null: false
    t.datetime "disabled_at"
    t.text "gemini_api_key"
    t.string "github_login"
    t.text "github_pat"
    t.boolean "is_site_admin", default: false, null: false
    t.text "minimax_api_key"
    t.text "moonshot_api_key"
    t.string "name", null: false
    t.text "openai_api_key"
    t.text "openrouter_api_key"
    t.jsonb "settings", default: {}
    t.string "slug"
    t.datetime "updated_at", null: false
    t.boolean "use_system_ai_credentials", default: false, null: false
    t.text "xai_api_key"
    t.text "zai_api_key"
    t.index ["account_type"], name: "index_accounts_on_account_type"
    t.index ["disabled_at"], name: "index_accounts_on_disabled_at"
    t.index ["slug"], name: "index_accounts_on_slug", unique: true
  end

  create_table "action_mcp_session_messages", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "direction", default: "client", null: false, comment: "The message recipient"
    t.boolean "is_ping", default: false, null: false, comment: "Whether the message is a ping"
    t.string "jsonrpc_id"
    t.json "message_json"
    t.string "message_type", null: false, comment: "The type of the message"
    t.boolean "request_acknowledged", default: false, null: false
    t.boolean "request_cancelled", default: false, null: false
    t.string "session_id", null: false
    t.datetime "updated_at", null: false
    t.index ["session_id"], name: "index_action_mcp_session_messages_on_session_id"
  end

  create_table "action_mcp_session_subscriptions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_notification_at"
    t.string "session_id", null: false
    t.datetime "updated_at", null: false
    t.string "uri", null: false
    t.index ["session_id"], name: "index_action_mcp_session_subscriptions_on_session_id"
  end

  create_table "action_mcp_session_tasks", id: :string, force: :cascade do |t|
    t.json "continuation_state", default: {}
    t.datetime "created_at", null: false
    t.datetime "last_step_at"
    t.datetime "last_updated_at", null: false
    t.integer "poll_interval", comment: "Suggested polling interval in milliseconds"
    t.string "progress_message", comment: "Human-readable progress message"
    t.integer "progress_percent", comment: "Task progress as percentage 0-100"
    t.string "request_method", comment: "e.g., tools/call, prompts/get"
    t.string "request_name", comment: "e.g., tool name, prompt name"
    t.json "request_params", comment: "Original request params"
    t.json "result_payload", comment: "Final result data"
    t.string "session_id", null: false
    t.string "status", default: "working", null: false
    t.string "status_message"
    t.integer "ttl", comment: "Time to live in milliseconds"
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_action_mcp_session_tasks_on_created_at"
    t.index ["session_id", "status"], name: "index_action_mcp_session_tasks_on_session_id_and_status"
    t.index ["session_id"], name: "index_action_mcp_session_tasks_on_session_id"
    t.index ["status"], name: "index_action_mcp_session_tasks_on_status"
  end

  create_table "action_mcp_sessions", id: :string, force: :cascade do |t|
    t.json "client_capabilities", comment: "The capabilities of the client"
    t.json "client_info", comment: "The information about the client"
    t.json "consents", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "ended_at", comment: "The time the session ended"
    t.boolean "initialized", default: false, null: false
    t.integer "messages_count", default: 0, null: false
    t.json "prompt_registry", default: []
    t.string "protocol_version"
    t.json "resource_registry", default: []
    t.string "role", default: "server", null: false, comment: "The role of the session"
    t.json "server_capabilities", comment: "The capabilities of the server"
    t.json "server_info", comment: "The information about the server"
    t.json "session_data", default: {}, null: false
    t.string "status", default: "pre_initialize", null: false
    t.json "tool_registry", default: []
    t.datetime "updated_at", null: false
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "agent_backup_snapshots", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.boolean "ok", default: false, null: false
    t.string "restic_snapshot_id", null: false
    t.bigint "size_bytes"
    t.text "stderr_tail"
    t.datetime "taken_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "taken_at"], name: "index_agent_backup_snapshots_on_agent_id_and_taken_at"
    t.index ["agent_id"], name: "index_agent_backup_snapshots_on_agent_id"
  end

  create_table "agent_memories", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.boolean "constitutional", default: false, null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.datetime "discarded_at"
    t.integer "memory_type", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "created_at"], name: "index_agent_memories_on_agent_id_and_created_at"
    t.index ["agent_id", "memory_type"], name: "index_agent_memories_on_agent_id_and_memory_type"
    t.index ["agent_id"], name: "index_agent_memories_on_agent_id"
    t.index ["discarded_at"], name: "index_agent_memories_on_discarded_at"
  end

  create_table "agent_runtime_interactions", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.bigint "cache_creation_input_tokens"
    t.bigint "cache_read_input_tokens"
    t.string "cache_ttl"
    t.bigint "cached_input_tokens"
    t.jsonb "changed_identity_files", default: []
    t.string "chaos_session_id"
    t.string "chaos_telemetry_status"
    t.string "chaos_version"
    t.bigint "chat_id"
    t.string "conversation_obfuscated_id"
    t.datetime "created_at", null: false
    t.bigint "delta_prompt_bytes"
    t.integer "duration_ms"
    t.string "endpoint_url"
    t.string "error_class"
    t.text "error_message"
    t.datetime "finished_at"
    t.boolean "fresh_fallback"
    t.text "full_invocation_text"
    t.bigint "full_prompt_bytes"
    t.bigint "input_tokens"
    t.bigint "last_included_message_id"
    t.string "model"
    t.bigint "output_tokens"
    t.boolean "persistent_session_requested"
    t.string "prior_chaos_session_id"
    t.jsonb "prompt_component_bytes", default: {}
    t.string "prompt_mode"
    t.string "provider"
    t.string "provider_auth_mode", default: "api_key", null: false
    t.integer "provider_request_count"
    t.bigint "reasoning_output_tokens"
    t.text "request_text"
    t.string "requested_by"
    t.jsonb "response_body", default: {}, null: false
    t.boolean "resume_attempted"
    t.integer "runtime_returncode"
    t.string "runtime_status"
    t.bigint "selected_prompt_bytes"
    t.integer "session_age_seconds"
    t.string "session_id"
    t.boolean "session_mapping_found"
    t.string "session_outcome"
    t.boolean "session_resumed"
    t.string "session_roll_reason"
    t.integer "session_trigger_sequence"
    t.datetime "started_at", null: false
    t.text "stderr"
    t.text "stdout"
    t.integer "telemetry_schema_version"
    t.integer "transport_status"
    t.string "trigger_kind", null: false
    t.bigint "uncached_input_tokens"
    t.integer "unsupported_chaos_telemetry_schema_version"
    t.datetime "updated_at", null: false
    t.boolean "usage_complete"
    t.string "usage_scope"
    t.index ["agent_id", "chaos_session_id", "started_at"], name: "idx_runtime_interactions_agent_chaos_started"
    t.index ["agent_id", "created_at"], name: "index_agent_runtime_interactions_on_agent_id_and_created_at"
    t.index ["agent_id", "session_id", "started_at"], name: "idx_runtime_interactions_agent_session_started"
    t.index ["agent_id", "session_outcome", "started_at"], name: "idx_runtime_interactions_agent_outcome_started"
    t.index ["agent_id", "session_roll_reason", "started_at"], name: "idx_runtime_interactions_agent_roll_reason_started"
    t.index ["agent_id"], name: "index_agent_runtime_interactions_on_agent_id"
    t.index ["chat_id", "created_at"], name: "index_agent_runtime_interactions_on_chat_id_and_created_at"
    t.index ["chat_id"], name: "index_agent_runtime_interactions_on_chat_id"
    t.index ["session_id"], name: "index_agent_runtime_interactions_on_session_id"
    t.index ["started_at"], name: "index_agent_runtime_interactions_on_started_at"
  end

  create_table "agent_service_accesses", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.boolean "follows_default", default: false, null: false
    t.datetime "provisioned_at"
    t.integer "provisioned_revision"
    t.string "provisioning_error_code"
    t.string "provisioning_status"
    t.bigint "service_connection_id", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "service_connection_id"], name: "idx_on_agent_id_service_connection_id_9030aefd71", unique: true
    t.index ["agent_id"], name: "index_agent_service_accesses_on_agent_id"
    t.index ["service_connection_id"], name: "index_agent_service_accesses_on_service_connection_id"
  end

  create_table "agents", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.boolean "active", default: true, null: false
    t.integer "backup_interval_hours", default: 24, null: false
    t.integer "backup_keep_daily", default: 7, null: false
    t.integer "backup_keep_monthly", default: 12, null: false
    t.integer "backup_keep_weekly", default: 4, null: false
    t.datetime "birth_committed_at"
    t.string "colour"
    t.integer "consecutive_health_failures", default: 0, null: false
    t.integer "container_cpu_shares", default: 1024, null: false
    t.string "container_image"
    t.integer "container_memory_mb", default: 8192, null: false
    t.string "container_name"
    t.datetime "created_at", null: false
    t.jsonb "enabled_tools", default: [], null: false
    t.string "endpoint_url"
    t.string "github_deploy_key_id"
    t.text "github_deploy_key_priv"
    t.string "github_repo_name"
    t.string "github_repo_owner"
    t.string "github_repo_url"
    t.string "health_state", default: "unknown", null: false
    t.integer "heartbeat_wakes_per_day", default: 2, null: false
    t.string "icon"
    t.datetime "identity_seeded_at"
    t.datetime "last_announced_at"
    t.datetime "last_health_check_at"
    t.datetime "last_refinement_at"
    t.text "memory_reflection_prompt"
    t.datetime "migration_started_at"
    t.string "model_id", default: "openrouter/auto", null: false
    t.string "name", null: false
    t.datetime "orientation_completed_at"
    t.text "orientation_last_error"
    t.datetime "orientation_last_error_at"
    t.datetime "orientation_requested_at"
    t.datetime "oriented_at"
    t.bigint "outbound_api_key_id"
    t.string "outbound_api_token"
    t.boolean "paused", default: false, null: false
    t.boolean "persistent_session", default: false, null: false
    t.boolean "persistent_wake_session", default: false, null: false
    t.jsonb "provider_auth_modes", default: {}, null: false
    t.jsonb "provider_connections", default: {}, null: false
    t.datetime "provisioning_started_at"
    t.string "reasoning_effort", default: "medium", null: false
    t.text "refinement_prompt"
    t.float "refinement_threshold"
    t.text "reflection_prompt"
    t.string "restic_password"
    t.string "runtime", default: "inline", null: false
    t.datetime "runtime_ready_at"
    t.string "sandbox_host"
    t.text "sandbox_last_error"
    t.datetime "sandbox_last_error_at"
    t.boolean "scheduled_wakes_enabled", default: true, null: false
    t.text "summary_prompt"
    t.text "system_prompt"
    t.string "telegram_bot_token"
    t.string "telegram_bot_username"
    t.string "telegram_webhook_token"
    t.integer "thinking_budget", default: 10000
    t.boolean "thinking_enabled", default: false, null: false
    t.string "trigger_bearer_token"
    t.datetime "updated_at", null: false
    t.uuid "uuid"
    t.string "voice_id"
    t.index ["account_id", "active"], name: "index_agents_on_account_id_and_active"
    t.index ["account_id", "name"], name: "index_agents_on_account_id_and_name", unique: true
    t.index ["account_id", "paused"], name: "index_agents_on_account_id_and_paused"
    t.index ["account_id"], name: "index_agents_on_account_id"
    t.index ["container_name"], name: "index_agents_on_container_name", unique: true
    t.index ["outbound_api_key_id"], name: "index_agents_on_outbound_api_key_id"
    t.index ["runtime"], name: "index_agents_on_runtime"
    t.index ["sandbox_host"], name: "index_agents_on_sandbox_host"
    t.index ["telegram_webhook_token"], name: "index_agents_on_telegram_webhook_token", unique: true
    t.index ["uuid"], name: "index_agents_on_uuid", unique: true
  end

  create_table "ai_models", force: :cascade do |t|
    t.jsonb "capabilities", default: []
    t.integer "context_window"
    t.datetime "created_at", null: false
    t.string "family"
    t.date "knowledge_cutoff"
    t.integer "max_output_tokens"
    t.jsonb "metadata", default: {}
    t.jsonb "modalities", default: {}
    t.datetime "model_created_at"
    t.string "model_id", null: false
    t.string "name", null: false
    t.jsonb "pricing", default: {}
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.index ["capabilities"], name: "index_ai_models_on_capabilities", using: :gin
    t.index ["family"], name: "index_ai_models_on_family"
    t.index ["modalities"], name: "index_ai_models_on_modalities", using: :gin
    t.index ["provider", "model_id"], name: "index_ai_models_on_provider_and_model_id", unique: true
    t.index ["provider"], name: "index_ai_models_on_provider"
  end

  create_table "api_key_requests", force: :cascade do |t|
    t.bigint "api_key_id"
    t.text "approved_token_encrypted"
    t.string "client_name", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "request_token", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["request_token"], name: "index_api_key_requests_on_request_token", unique: true
  end

  create_table "api_keys", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "agent_id"
    t.datetime "created_at", null: false
    t.datetime "last_used_at"
    t.string "last_used_ip"
    t.string "name", null: false
    t.string "token_digest", null: false
    t.string "token_prefix", limit: 8, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["account_id"], name: "index_api_keys_on_account_id"
    t.index ["agent_id"], name: "index_api_keys_on_agent_id", unique: true, where: "(agent_id IS NOT NULL)"
    t.index ["token_digest"], name: "index_api_keys_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_keys_on_user_id"
  end

  create_table "audit_logs", force: :cascade do |t|
    t.bigint "account_id"
    t.string "action", null: false
    t.bigint "auditable_id"
    t.string "auditable_type"
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}
    t.string "ip_address"
    t.string "user_agent"
    t.bigint "user_id"
    t.index ["account_id", "created_at"], name: "index_audit_logs_on_account_id_and_created_at"
    t.index ["account_id"], name: "index_audit_logs_on_account_id"
    t.index ["action"], name: "index_audit_logs_on_action"
    t.index ["auditable_type", "auditable_id"], name: "index_audit_logs_on_auditable"
    t.index ["auditable_type", "auditable_id"], name: "index_audit_logs_on_auditable_type_and_auditable_id"
    t.index ["created_at"], name: "index_audit_logs_on_created_at"
    t.index ["user_id"], name: "index_audit_logs_on_user_id"
  end

  create_table "chat_agents", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.text "agent_summary"
    t.datetime "agent_summary_generated_at"
    t.jsonb "borrowed_context_json"
    t.bigint "chat_id", null: false
    t.datetime "closed_for_initiation_at"
    t.datetime "created_at", null: false
    t.index ["agent_id", "agent_summary_generated_at"], name: "index_chat_agents_on_agent_summary_recency"
    t.index ["agent_id", "closed_for_initiation_at"], name: "index_chat_agents_on_agent_closed_initiation"
    t.index ["agent_id"], name: "index_chat_agents_on_agent_id"
    t.index ["chat_id", "agent_id"], name: "index_chat_agents_on_chat_id_and_agent_id", unique: true
    t.index ["chat_id"], name: "index_chat_agents_on_chat_id"
  end

  create_table "chats", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "active_whiteboard_id"
    t.bigint "ai_model_id"
    t.datetime "archived_at"
    t.text "checkpoint_summary"
    t.integer "context_tokens", default: 0, null: false
    t.datetime "created_at", null: false
    t.text "debug_log"
    t.datetime "discarded_at"
    t.bigint "initiated_by_agent_id"
    t.text "initiation_reason"
    t.datetime "last_consolidated_at"
    t.bigint "last_consolidated_message_id"
    t.boolean "manual_responses", default: false, null: false
    t.string "model_id_string", default: "openrouter/auto", null: false
    t.string "prompt_timezone"
    t.text "summary"
    t.datetime "summary_generated_at"
    t.string "title"
    t.datetime "updated_at", null: false
    t.boolean "web_access", default: false, null: false
    t.index ["account_id", "created_at"], name: "index_chats_on_account_id_and_created_at"
    t.index ["account_id"], name: "index_chats_on_account_id"
    t.index ["active_whiteboard_id"], name: "index_chats_on_active_whiteboard_id"
    t.index ["ai_model_id"], name: "index_chats_on_ai_model_id"
    t.index ["archived_at"], name: "index_chats_on_archived_at"
    t.index ["discarded_at"], name: "index_chats_on_discarded_at"
    t.index ["initiated_by_agent_id"], name: "index_chats_on_initiated_by_agent_id"
    t.index ["last_consolidated_at"], name: "index_chats_on_last_consolidated_at"
    t.index ["manual_responses"], name: "index_chats_on_manual_responses"
    t.index ["web_access"], name: "index_chats_on_web_access"
  end

  create_table "conversation_compactions", force: :cascade do |t|
    t.bigint "boundary_message_id", null: false
    t.bigint "cache_creation_tokens"
    t.bigint "cached_tokens"
    t.bigint "chat_id", null: false
    t.integer "compacted_message_count", null: false
    t.datetime "created_at", null: false
    t.bigint "input_tokens"
    t.string "model", null: false
    t.bigint "output_tokens"
    t.string "provider", null: false
    t.text "summary", null: false
    t.bigint "thinking_tokens"
    t.datetime "updated_at", null: false
    t.index ["chat_id", "boundary_message_id"], name: "idx_on_chat_id_boundary_message_id_cb11697831", unique: true
    t.index ["chat_id", "created_at"], name: "index_conversation_compactions_on_chat_id_and_created_at"
    t.index ["chat_id"], name: "index_conversation_compactions_on_chat_id"
  end

  create_table "github_integrations", force: :cascade do |t|
    t.text "access_token"
    t.bigint "account_id", null: false
    t.datetime "commits_synced_at"
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "github_username"
    t.jsonb "recent_commits", default: []
    t.string "repository_full_name"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_github_integrations_on_account_id", unique: true
  end

  create_table "memberships", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "confirmation_sent_at"
    t.string "confirmation_token"
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.datetime "invitation_accepted_at"
    t.datetime "invited_at"
    t.bigint "invited_by_id"
    t.string "role", default: "owner", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["account_id", "user_id"], name: "index_memberships_on_account_id_and_user_id", unique: true
    t.index ["account_id"], name: "index_memberships_on_account_id"
    t.index ["confirmation_token"], name: "index_memberships_on_confirmation_token", unique: true
    t.index ["confirmed_at"], name: "index_memberships_on_confirmed_at"
    t.index ["invitation_accepted_at"], name: "index_memberships_on_invitation_accepted_at"
    t.index ["invited_by_id"], name: "index_memberships_on_invited_by_id"
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "messages", force: :cascade do |t|
    t.bigint "agent_id"
    t.bigint "ai_model_id"
    t.boolean "audio_source", default: false, null: false
    t.integer "cache_creation_tokens"
    t.integer "cached_tokens"
    t.bigint "chat_id", null: false
    t.text "content"
    t.datetime "created_at", null: false
    t.integer "envelope_prompt_bytes"
    t.integer "input_tokens"
    t.string "model_id_string"
    t.datetime "moderated_at"
    t.jsonb "moderation_scores"
    t.integer "output_tokens"
    t.integer "prompt_layout_version"
    t.string "reasoning_skip_reason"
    t.jsonb "replay_payload"
    t.string "role", null: false
    t.integer "stable_prompt_bytes"
    t.string "stable_prompt_sha256"
    t.boolean "streaming", default: false, null: false
    t.text "thinking_text"
    t.integer "thinking_tokens"
    t.bigint "tool_call_id"
    t.string "tool_status"
    t.text "tools_used", default: [], array: true
    t.integer "transcript_prompt_bytes"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["agent_id"], name: "index_messages_on_agent_id"
    t.index ["ai_model_id"], name: "index_messages_on_ai_model_id"
    t.index ["chat_id", "created_at"], name: "index_messages_on_chat_id_and_created_at"
    t.index ["chat_id"], name: "index_messages_on_chat_id"
    t.index ["reasoning_skip_reason"], name: "index_messages_on_reasoning_skip_reason", where: "(reasoning_skip_reason IS NOT NULL)"
    t.index ["streaming"], name: "index_messages_on_streaming"
    t.index ["tool_call_id"], name: "index_messages_on_tool_call_id"
    t.index ["tools_used"], name: "index_messages_on_tools_used", using: :gin
    t.index ["user_id"], name: "index_messages_on_user_id"
  end

  create_table "notices", force: :cascade do |t|
    t.bigint "account_id"
    t.text "body"
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.datetime "expires_at", null: false
    t.string "notice_type", null: false
    t.jsonb "params", default: {}, null: false
    t.string "scope", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_notices_on_account_id"
    t.index ["created_by_id"], name: "index_notices_on_created_by_id"
    t.index ["expires_at"], name: "index_notices_on_expires_at"
    t.index ["scope", "account_id", "expires_at"], name: "index_notices_on_scope_and_account_id_and_expires_at"
  end

  create_table "oura_integrations", force: :cascade do |t|
    t.text "access_token"
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.jsonb "health_data", default: {}
    t.datetime "health_data_synced_at"
    t.text "refresh_token"
    t.datetime "token_expires_at"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_oura_integrations_on_user_id", unique: true
  end

  create_table "profiles", force: :cascade do |t|
    t.string "chat_colour"
    t.datetime "created_at", null: false
    t.string "first_name"
    t.string "last_name"
    t.jsonb "preferences", default: {}
    t.string "theme", default: "system"
    t.string "timezone"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_profiles_on_user_id", unique: true
  end

  create_table "prompt_outputs", force: :cascade do |t|
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.text "output"
    t.jsonb "output_json", default: {}
    t.string "prompt_key"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_prompt_outputs_on_account_id"
    t.index ["created_at"], name: "index_prompt_outputs_on_created_at"
    t.index ["prompt_key"], name: "index_prompt_outputs_on_prompt_key"
  end

  create_table "safeguard_classifier_failures", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.datetime "created_at", null: false
    t.string "detector_version", null: false
    t.string "error_class", null: false
    t.string "model", null: false
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "created_at"], name: "index_safeguard_classifier_failures_on_agent_id_and_created_at"
    t.index ["agent_id"], name: "index_safeguard_classifier_failures_on_agent_id"
  end

  create_table "safeguard_detections", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.bigint "agent_runtime_interaction_id"
    t.string "channel", default: "telegram", null: false
    t.string "classifier_reason", null: false
    t.string "classifier_verdict", null: false
    t.string "cold_offer_outcome"
    t.datetime "created_at", null: false
    t.string "detector_version", null: false
    t.string "model"
    t.string "prefilter_reason", null: false
    t.string "provider"
    t.string "reclaim_reason"
    t.datetime "reclaimed_at"
    t.bigint "reclaimed_by_interaction_id"
    t.text "response_text"
    t.datetime "response_text_redacted_at"
    t.datetime "session_rolled_at"
    t.bigint "telegram_message_id"
    t.datetime "updated_at", null: false
    t.index ["agent_id", "created_at"], name: "index_safeguard_detections_on_agent_id_and_created_at"
    t.index ["agent_id"], name: "index_safeguard_detections_on_agent_id"
    t.index ["agent_runtime_interaction_id"], name: "index_safeguard_detections_on_agent_runtime_interaction_id"
    t.index ["detector_version", "created_at"], name: "index_safeguard_detections_on_detector_version_and_created_at"
    t.index ["provider", "model", "created_at"], name: "idx_on_provider_model_created_at_74b1db80f1"
    t.index ["reclaimed_by_interaction_id"], name: "index_safeguard_detections_on_reclaimed_by_interaction_id"
    t.index ["response_text_redacted_at"], name: "index_safeguard_detections_on_response_text_redacted_at"
    t.index ["telegram_message_id"], name: "index_safeguard_detections_on_telegram_message_id"
  end

  create_table "service_authorization_attempts", force: :cascade do |t|
    t.string "access_profile"
    t.bigint "account_id", null: false
    t.jsonb "authority_selection", default: {}, null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "management_scope", null: false
    t.text "pkce_verifier"
    t.string "provider", null: false
    t.jsonb "requested_scopes", default: [], null: false
    t.string "return_path"
    t.bigint "service_connection_id"
    t.string "state_digest", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["account_id"], name: "index_service_authorization_attempts_on_account_id"
    t.index ["service_connection_id"], name: "index_service_authorization_attempts_on_service_connection_id"
    t.index ["state_digest"], name: "index_service_authorization_attempts_on_state_digest", unique: true
    t.index ["user_id"], name: "index_service_authorization_attempts_on_user_id"
  end

  create_table "service_connections", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "connected_by_user_id", null: false
    t.datetime "created_at", null: false
    t.string "credential_fingerprint"
    t.string "credential_kind", null: false
    t.jsonb "credential_metadata", default: {}, null: false
    t.text "credential_payload"
    t.integer "credential_revision", default: 1, null: false
    t.boolean "enabled_for_new_agents", default: false, null: false
    t.string "external_identity"
    t.string "external_subject_id"
    t.boolean "freely_provisionable", default: false, null: false
    t.string "label"
    t.bigint "legacy_oura_integration_id"
    t.string "management_scope", default: "personal", null: false
    t.string "provider", null: false
    t.string "status", default: "connected", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "provider", "credential_fingerprint"], name: "index_service_connections_on_account_provider_credential", unique: true, where: "(credential_fingerprint IS NOT NULL)"
    t.index ["account_id", "provider", "external_subject_id"], name: "index_service_connections_on_account_provider_subject", unique: true, where: "((external_subject_id IS NOT NULL) AND (credential_fingerprint IS NULL))"
    t.index ["account_id"], name: "index_service_connections_on_account_id"
    t.index ["connected_by_user_id"], name: "index_service_connections_on_connected_by_user_id"
    t.index ["legacy_oura_integration_id"], name: "index_service_connections_on_legacy_oura_integration_id"
    t.index ["legacy_oura_integration_id"], name: "index_service_connections_on_unique_legacy_oura", unique: true, where: "(legacy_oura_integration_id IS NOT NULL)"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "settings", force: :cascade do |t|
    t.boolean "allow_agents", default: false, null: false
    t.boolean "allow_chats", default: true, null: false
    t.boolean "allow_signups", default: true, null: false
    t.datetime "created_at", null: false
    t.integer "safeguard_owner_notice_threshold", default: 1, null: false
    t.boolean "show_usage_in_chat", default: false, null: false
    t.string "site_name", default: "HelixKit", null: false
    t.datetime "updated_at", null: false
  end

  create_table "telegram_messages", force: :cascade do |t|
    t.text "caption"
    t.datetime "created_at", null: false
    t.string "media_error"
    t.string "media_kind"
    t.jsonb "media_metadata", default: {}, null: false
    t.string "media_status"
    t.string "role", null: false
    t.string "sender_name"
    t.string "sender_username"
    t.datetime "sent_at", null: false
    t.bigint "telegram_message_id"
    t.bigint "telegram_subscription_id", null: false
    t.text "text", null: false
    t.text "transcription"
    t.datetime "updated_at", null: false
    t.datetime "wake_enqueued_at"
    t.index ["telegram_subscription_id", "telegram_message_id"], name: "idx_on_telegram_subscription_id_telegram_message_id_9eb10802be", unique: true, where: "(telegram_message_id IS NOT NULL)"
    t.index ["telegram_subscription_id"], name: "index_telegram_messages_on_telegram_subscription_id"
  end

  create_table "telegram_subscriptions", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.boolean "blocked", default: false
    t.datetime "created_at", null: false
    t.bigint "pending_safeguard_detection_id"
    t.integer "runtime_session_generation", default: 0, null: false
    t.bigint "telegram_chat_id", null: false
    t.string "telegram_username"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["agent_id", "telegram_chat_id"], name: "index_telegram_subscriptions_on_agent_id_and_telegram_chat_id", unique: true
    t.index ["agent_id", "user_id"], name: "index_telegram_subscriptions_on_agent_id_and_user_id", unique: true
    t.index ["agent_id"], name: "index_telegram_subscriptions_on_agent_id"
    t.index ["pending_safeguard_detection_id"], name: "index_telegram_subscriptions_on_pending_safeguard_detection_id"
    t.index ["user_id"], name: "index_telegram_subscriptions_on_user_id"
  end

  create_table "tool_calls", force: :cascade do |t|
    t.jsonb "arguments", default: {}
    t.datetime "created_at", null: false
    t.bigint "message_id", null: false
    t.jsonb "metadata", default: {}
    t.string "name", null: false
    t.jsonb "replay_payload"
    t.string "tool_call_id", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id"], name: "index_tool_calls_on_message_id"
    t.index ["tool_call_id"], name: "index_tool_calls_on_tool_call_id"
  end

  create_table "tweet_logs", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.datetime "created_at", null: false
    t.text "text", null: false
    t.string "tweet_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "x_integration_id", null: false
    t.index ["agent_id"], name: "index_tweet_logs_on_agent_id"
    t.index ["tweet_id"], name: "index_tweet_logs_on_tweet_id", unique: true
    t.index ["x_integration_id"], name: "index_tweet_logs_on_x_integration_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.boolean "is_site_admin", default: false, null: false
    t.boolean "migrated_to_accounts", default: false
    t.string "password_digest"
    t.datetime "password_reset_sent_at"
    t.string "password_reset_token"
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.index ["password_reset_token"], name: "index_users_on_password_reset_token", unique: true
  end

  create_table "whiteboards", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.text "content"
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.datetime "last_edited_at"
    t.bigint "last_edited_by_id"
    t.string "last_edited_by_type"
    t.integer "lock_version", default: 0, null: false
    t.string "name", null: false
    t.integer "revision", default: 1, null: false
    t.string "summary", limit: 250
    t.datetime "updated_at", null: false
    t.index ["account_id", "deleted_at"], name: "index_whiteboards_on_account_id_and_deleted_at"
    t.index ["account_id", "name"], name: "index_whiteboards_on_account_id_and_name", unique: true, where: "(deleted_at IS NULL)"
    t.index ["account_id"], name: "index_whiteboards_on_account_id"
    t.index ["last_edited_by_type", "last_edited_by_id"], name: "index_whiteboards_on_last_edited_by"
  end

  create_table "x_integrations", force: :cascade do |t|
    t.text "access_token"
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.text "refresh_token"
    t.datetime "token_expires_at"
    t.datetime "updated_at", null: false
    t.string "x_username"
    t.index ["account_id"], name: "index_x_integrations_on_account_id", unique: true
  end

  add_foreign_key "action_mcp_session_messages", "action_mcp_sessions", column: "session_id", name: "fk_action_mcp_session_messages_session_id", on_update: :cascade, on_delete: :cascade
  add_foreign_key "action_mcp_session_subscriptions", "action_mcp_sessions", column: "session_id", on_delete: :cascade
  add_foreign_key "action_mcp_session_tasks", "action_mcp_sessions", column: "session_id", name: "fk_action_mcp_session_tasks_session_id", on_update: :cascade, on_delete: :cascade
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "agent_backup_snapshots", "agents"
  add_foreign_key "agent_memories", "agents"
  add_foreign_key "agent_runtime_interactions", "agents"
  add_foreign_key "agent_runtime_interactions", "chats"
  add_foreign_key "agent_service_accesses", "agents"
  add_foreign_key "agent_service_accesses", "service_connections"
  add_foreign_key "agents", "accounts"
  add_foreign_key "agents", "api_keys", column: "outbound_api_key_id"
  add_foreign_key "api_key_requests", "api_keys"
  add_foreign_key "api_keys", "accounts"
  add_foreign_key "api_keys", "agents"
  add_foreign_key "api_keys", "users"
  add_foreign_key "audit_logs", "accounts"
  add_foreign_key "audit_logs", "users"
  add_foreign_key "chat_agents", "agents"
  add_foreign_key "chat_agents", "chats"
  add_foreign_key "chats", "accounts"
  add_foreign_key "chats", "agents", column: "initiated_by_agent_id"
  add_foreign_key "chats", "ai_models"
  add_foreign_key "chats", "whiteboards", column: "active_whiteboard_id"
  add_foreign_key "conversation_compactions", "chats"
  add_foreign_key "github_integrations", "accounts"
  add_foreign_key "memberships", "accounts"
  add_foreign_key "memberships", "users"
  add_foreign_key "memberships", "users", column: "invited_by_id"
  add_foreign_key "messages", "agents"
  add_foreign_key "messages", "ai_models"
  add_foreign_key "messages", "chats"
  add_foreign_key "messages", "users"
  add_foreign_key "notices", "accounts"
  add_foreign_key "notices", "users", column: "created_by_id"
  add_foreign_key "oura_integrations", "users"
  add_foreign_key "profiles", "users"
  add_foreign_key "prompt_outputs", "accounts"
  add_foreign_key "safeguard_classifier_failures", "agents"
  add_foreign_key "safeguard_detections", "agent_runtime_interactions", column: "reclaimed_by_interaction_id", on_delete: :nullify
  add_foreign_key "safeguard_detections", "agent_runtime_interactions", on_delete: :nullify
  add_foreign_key "safeguard_detections", "agents"
  add_foreign_key "safeguard_detections", "telegram_messages", on_delete: :nullify
  add_foreign_key "service_authorization_attempts", "accounts"
  add_foreign_key "service_authorization_attempts", "service_connections"
  add_foreign_key "service_authorization_attempts", "users"
  add_foreign_key "service_connections", "accounts"
  add_foreign_key "service_connections", "oura_integrations", column: "legacy_oura_integration_id"
  add_foreign_key "service_connections", "users", column: "connected_by_user_id"
  add_foreign_key "sessions", "users"
  add_foreign_key "telegram_messages", "telegram_subscriptions"
  add_foreign_key "telegram_subscriptions", "agents"
  add_foreign_key "telegram_subscriptions", "safeguard_detections", column: "pending_safeguard_detection_id", on_delete: :nullify
  add_foreign_key "telegram_subscriptions", "users"
  add_foreign_key "tool_calls", "messages"
  add_foreign_key "tweet_logs", "agents"
  add_foreign_key "tweet_logs", "x_integrations"
  add_foreign_key "whiteboards", "accounts"
  add_foreign_key "x_integrations", "accounts"
end
