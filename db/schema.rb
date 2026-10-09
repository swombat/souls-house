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

ActiveRecord::Schema[8.1].define(version: 2026_10_09_230000) do
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
    t.string "logo_colour"
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
    t.bigint "recording_ms_weekly_limit", default: 72000000, null: false
    t.boolean "recognise_voices", default: false, null: false
    t.boolean "founding", default: false, null: false
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
    t.string "graph_checkpoint_digest"
    t.integer "graph_schema_version"
    t.boolean "ok", default: false, null: false
    t.string "restic_snapshot_id", null: false
    t.bigint "size_bytes"
    t.text "stderr_tail"
    t.datetime "taken_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "taken_at"], name: "index_agent_backup_snapshots_on_agent_id_and_taken_at"
    t.index ["agent_id"], name: "index_agent_backup_snapshots_on_agent_id"
  end

  create_table "agent_bookmarks", force: :cascade do |t|
    t.bigint "chat_agent_id", null: false
    t.datetime "created_at", null: false
    t.text "note", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_agent_id"], name: "index_agent_bookmarks_on_chat_agent_id", unique: true
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

  create_table "agent_placements", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.string "backend", default: "local", null: false
    t.string "state", default: "pending", null: false
    t.bigint "provider_server_id"
    t.string "runtime_endpoint"
    t.integer "generation", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "location"
    t.datetime "admitted_by_setting_at"
    t.datetime "birth_deadline_at"
    t.bigint "birth_requested_by_id"
    t.string "cleanup_reason"
    t.datetime "cleanup_requested_at"
    t.bigint "first_backup_command_id"
    t.binary "seed_archive"
    t.string "seed_sha256"
    t.datetime "seeded_at"
    t.index ["agent_id"], name: "index_agent_placements_on_agent_id", unique: true
    t.index ["cleanup_requested_at"], name: "index_agent_placements_on_cleanup_requested_at", where: "(cleanup_requested_at IS NOT NULL)"
    t.index ["provider_server_id"], name: "index_agent_placements_on_provider_server_id", unique: true, where: "(provider_server_id IS NOT NULL)"
    t.check_constraint "generation >= 1", name: "agent_placements_positive_generation"
    t.check_constraint "provider_server_id > 0", name: "agent_placements_positive_server_id"
  end

  create_table "agent_runtime_attempts", force: :cascade do |t|
    t.bigint "agent_runtime_interaction_id", null: false
    t.string "attempt_id", null: false
    t.datetime "created_at", null: false
    t.integer "detail_bytes", default: 0, null: false
    t.integer "detail_count", default: 0, null: false
    t.integer "dropped_count", default: 0, null: false
    t.datetime "last_broadcast_at"
    t.datetime "last_report_at"
    t.integer "last_seq", default: 0, null: false
    t.integer "number", null: false
    t.integer "revision", default: 0, null: false
    t.jsonb "snapshot", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["agent_runtime_interaction_id", "number"], name: "idx_runtime_attempt_number", unique: true
    t.index ["attempt_id"], name: "index_agent_runtime_attempts_on_attempt_id", unique: true
  end

  create_table "agent_runtime_events", force: :cascade do |t|
    t.bigint "agent_runtime_attempt_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}, null: false
    t.string "event_type", null: false
    t.string "payload_digest", null: false
    t.integer "seq", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_runtime_attempt_id", "seq"], name: "idx_runtime_event_sequence", unique: true
    t.index ["agent_runtime_attempt_id"], name: "index_agent_runtime_events_on_agent_runtime_attempt_id"
  end

  create_table "agent_runtime_interactions", force: :cascade do |t|
    t.string "activity_token_digest"
    t.datetime "activity_token_expires_at"
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
    t.datetime "dispatch_claimed_at"
    t.integer "duration_ms"
    t.string "endpoint_url"
    t.string "error_class"
    t.text "error_message"
    t.datetime "execution_deadline_at"
    t.string "execution_state"
    t.datetime "finished_at"
    t.boolean "fresh_fallback"
    t.text "full_invocation_text"
    t.bigint "full_prompt_bytes"
    t.bigint "input_tokens"
    t.bigint "last_included_message_id"
    t.bigint "message_dispatch_id"
    t.string "model"
    t.boolean "narration_shared", default: false, null: false
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
    t.datetime "response_chain_advanced_at"
    t.jsonb "response_chain_agent_ids", default: [], null: false
    t.boolean "resume_attempted"
    t.string "run_id"
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
    t.bigint "follow_through_of_id"
    t.datetime "follow_through_checked_at"
    t.index ["agent_id", "chaos_session_id", "started_at"], name: "idx_runtime_interactions_agent_chaos_started"
    t.index ["agent_id", "created_at"], name: "index_agent_runtime_interactions_on_agent_id_and_created_at"
    t.index ["agent_id", "session_id", "started_at"], name: "idx_runtime_interactions_agent_session_started"
    t.index ["agent_id", "session_outcome", "started_at"], name: "idx_runtime_interactions_agent_outcome_started"
    t.index ["agent_id", "session_roll_reason", "started_at"], name: "idx_runtime_interactions_agent_roll_reason_started"
    t.index ["agent_id"], name: "index_agent_runtime_interactions_on_agent_id"
    t.index ["chat_id", "created_at"], name: "index_agent_runtime_interactions_on_chat_id_and_created_at"
    t.index ["chat_id"], name: "index_agent_runtime_interactions_on_chat_id"
    t.index ["follow_through_of_id"], name: "index_agent_runtime_interactions_on_follow_through_of_id", unique: true, where: "(follow_through_of_id IS NOT NULL)"
    t.index ["message_dispatch_id"], name: "index_agent_runtime_interactions_on_message_dispatch_id"
    t.index ["run_id"], name: "index_agent_runtime_interactions_on_run_id", unique: true
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
    t.datetime "deprecated_at"
    t.string "deprecation_reason"
    t.jsonb "enabled_tools", default: [], null: false
    t.string "endpoint_url"
    t.string "github_deploy_key_id"
    t.text "github_deploy_key_priv"
    t.string "github_repo_name"
    t.string "github_repo_owner"
    t.string "github_repo_url"
    t.string "health_state", default: "unknown", null: false
    t.integer "heartbeat_wakes_per_day", default: 2, null: false
    t.string "home_profile", default: "house", null: false
    t.string "icon"
    t.datetime "identity_seeded_at"
    t.jsonb "journal_entry_stats", default: {}, null: false
    t.datetime "journal_stats_requested_at"
    t.datetime "last_announced_at"
    t.datetime "last_health_check_at"
    t.datetime "last_refinement_at"
    t.datetime "memory_erased_at"
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
    t.string "portable_home_id"
    t.jsonb "portability_custody", default: {}, null: false
    t.jsonb "provider_auth_modes", default: {}, null: false
    t.jsonb "provider_connections", default: {}, null: false
    t.datetime "provisioning_started_at"
    t.string "reasoning_effort", default: "medium", null: false
    t.text "refinement_prompt"
    t.float "refinement_threshold"
    t.text "reflection_prompt"
    t.string "restic_password"
    t.string "runtime", default: "deprecated", null: false
    t.datetime "runtime_ready_at"
    t.string "sandbox_host"
    t.text "sandbox_last_error"
    t.datetime "sandbox_last_error_at"
    t.boolean "scheduled_wakes_enabled", default: true, null: false
    t.integer "session_context_budget_tokens", default: 300000, null: false
    t.integer "session_idle_timeout_minutes", default: 45, null: false
    t.integer "session_max_age_minutes", default: 240, null: false
    t.boolean "share_working_narration", default: true, null: false
    t.jsonb "storage_usage", default: {}, null: false
    t.text "summary_prompt"
    t.text "system_prompt"
    t.string "telegram_bot_token"
    t.string "telegram_bot_username"
    t.string "telegram_webhook_token"
    t.integer "thinking_budget", default: 10000
    t.boolean "thinking_enabled", default: false, null: false
    t.string "trigger_bearer_token"
    t.integer "turn_timeout_minutes", default: 30, null: false
    t.datetime "updated_at", null: false
    t.uuid "uuid"
    t.string "voice_id"
    t.boolean "subagents_enabled", default: false, null: false
    t.jsonb "subagent_models", default: [], null: false
    t.datetime "subagents_policy_changed_at"
    t.bigint "github_resident_import_id"
    t.boolean "follow_through", default: false, null: false
    t.jsonb "switchable_model_ids", default: [], null: false
    t.boolean "resident_may_switch_model", default: false, null: false
    t.index ["account_id", "active"], name: "index_agents_on_account_id_and_active"
    t.index ["account_id", "name"], name: "index_agents_on_account_id_and_name", unique: true
    t.index ["account_id", "paused"], name: "index_agents_on_account_id_and_paused"
    t.index ["account_id"], name: "index_agents_on_account_id"
    t.index ["container_name"], name: "index_agents_on_container_name", unique: true
    t.index ["github_resident_import_id"], name: "index_agents_on_github_resident_import_id", unique: true
    t.index ["outbound_api_key_id"], name: "index_agents_on_outbound_api_key_id"
    t.index ["portable_home_id"], name: "index_agents_on_portable_home_id", unique: true
    t.index ["runtime"], name: "index_agents_on_runtime"
    t.index ["sandbox_host"], name: "index_agents_on_sandbox_host"
    t.index ["telegram_webhook_token"], name: "index_agents_on_telegram_webhook_token", unique: true
    t.index ["uuid"], name: "index_agents_on_uuid", unique: true
    t.check_constraint "turn_timeout_minutes >= 1 AND turn_timeout_minutes <= 1440", name: "agents_turn_timeout_minutes_range"
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

  create_table "app_cable_tickets", force: :cascade do |t|
    t.bigint "app_session_id", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "token_digest", null: false
    t.index ["app_session_id"], name: "index_app_cable_tickets_on_app_session_id"
    t.index ["token_digest"], name: "index_app_cable_tickets_on_token_digest", unique: true
  end

  create_table "app_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "device_label"
    t.datetime "last_used_at"
    t.bigint "oauth_application_id", null: false
    t.string "revocation_reason"
    t.datetime "revoked_at"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["oauth_application_id"], name: "index_app_sessions_on_oauth_application_id"
    t.index ["user_id"], name: "index_app_sessions_on_user_id"
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
    t.integer "safeguard_reset_requested_generation", default: 0, null: false
    t.integer "safeguard_reset_acknowledged_generation", default: 0, null: false
    t.string "model_id"
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
    t.string "client_conversation_id"
    t.integer "context_tokens", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "creation_digest"
    t.text "debug_log"
    t.datetime "discarded_at"
    t.bigint "initiated_by_agent_id"
    t.text "initiation_reason"
    t.datetime "last_consolidated_at"
    t.bigint "last_consolidated_message_id"
    t.datetime "last_message_at"
    t.boolean "manual_responses", default: false, null: false
    t.bigint "message_revision", default: 0, null: false
    t.string "model_id_string", default: "openrouter/auto", null: false
    t.string "prompt_timezone"
    t.text "summary"
    t.datetime "summary_generated_at"
    t.string "title"
    t.datetime "updated_at", null: false
    t.boolean "web_access", default: false, null: false
    t.bigint "visual_tag_id"
    t.index ["account_id", "client_conversation_id"], name: "index_chats_on_client_conversation_identity", unique: true, where: "(client_conversation_id IS NOT NULL)"
    t.index ["account_id", "created_at"], name: "index_chats_on_account_id_and_created_at"
    t.index ["account_id"], name: "index_chats_on_account_id"
    t.index ["active_whiteboard_id"], name: "index_chats_on_active_whiteboard_id"
    t.index ["ai_model_id"], name: "index_chats_on_ai_model_id"
    t.index ["archived_at"], name: "index_chats_on_archived_at"
    t.index ["discarded_at"], name: "index_chats_on_discarded_at"
    t.index ["initiated_by_agent_id"], name: "index_chats_on_initiated_by_agent_id"
    t.index ["last_consolidated_at"], name: "index_chats_on_last_consolidated_at"
    t.index ["manual_responses"], name: "index_chats_on_manual_responses"
    t.index ["visual_tag_id"], name: "index_chats_on_visual_tag_id"
    t.index ["web_access"], name: "index_chats_on_web_access"
  end

  create_table "cloud_procurement_operations", force: :cascade do |t|
    t.bigint "agent_placement_id", null: false
    t.bigint "requested_by_id", null: false
    t.string "public_id", null: false
    t.string "state", default: "planned", null: false
    t.string "approval_reference", null: false
    t.string "location", null: false
    t.string "server_type", null: false
    t.bigint "image_id", null: false
    t.jsonb "ssh_key_ids", default: [], null: false
    t.string "provider_name", null: false
    t.bigint "provider_server_id"
    t.bigint "create_action_id"
    t.bigint "delete_action_id"
    t.string "ipv4"
    t.string "ipv6"
    t.string "last_error_code"
    t.string "review_reason"
    t.datetime "create_sent_at"
    t.datetime "provisioned_at"
    t.datetime "delete_requested_at"
    t.datetime "deleted_at"
    t.datetime "last_reconciled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_placement_id"], name: "index_cloud_procurement_operations_one_unresolved", unique: true, where: "((state)::text <> ALL ((ARRAY['refused'::character varying, 'deleted'::character varying])::text[]))"
    t.index ["location", "state"], name: "index_cloud_procurement_operations_on_location_and_state"
    t.index ["provider_name"], name: "index_cloud_procurement_operations_on_provider_name", unique: true
    t.index ["provider_server_id"], name: "index_cloud_procurement_operations_on_provider_server_id", unique: true, where: "(provider_server_id IS NOT NULL)"
    t.index ["public_id"], name: "index_cloud_procurement_operations_on_public_id", unique: true
    t.index ["requested_by_id"], name: "index_cloud_procurement_operations_on_requested_by_id"
    t.check_constraint "image_id > 0", name: "cloud_procurement_operations_positive_image_id"
    t.check_constraint "provider_server_id > 0", name: "cloud_procurement_operations_positive_server_id"
    t.check_constraint "state::text = ANY (ARRAY['planned'::character varying, 'create_in_flight'::character varying, 'reconciling'::character varying, 'provisioned'::character varying, 'unknown'::character varying, 'refused'::character varying, 'needs_review'::character varying, 'deleting'::character varying, 'deleted'::character varying]::text[])", name: "cloud_procurement_operations_state"
  end

  create_table "comms_chats", force: :cascade do |t|
    t.bigint "service_connection_id", null: false
    t.string "provider_chat_id", null: false
    t.text "name"
    t.string "kind"
    t.datetime "last_activity_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["service_connection_id", "last_activity_at"], name: "idx_on_service_connection_id_last_activity_at_96e688631f"
    t.index ["service_connection_id", "provider_chat_id"], name: "idx_on_service_connection_id_provider_chat_id_15d91caed6", unique: true
    t.index ["service_connection_id"], name: "index_comms_chats_on_service_connection_id"
  end

  create_table "comms_messages", force: :cascade do |t|
    t.bigint "service_connection_id", null: false
    t.bigint "comms_chat_id", null: false
    t.string "provider_message_id", null: false
    t.text "sender_id"
    t.text "sender_name"
    t.datetime "sent_at", null: false
    t.text "body"
    t.string "media_kind"
    t.text "caption"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["comms_chat_id", "sent_at", "id"], name: "index_comms_messages_on_comms_chat_id_and_sent_at_and_id"
    t.index ["service_connection_id", "provider_message_id"], name: "idx_on_service_connection_id_provider_message_id_12b2c5454b", unique: true
  end

  create_table "comms_request_nonces", force: :cascade do |t|
    t.bigint "service_connection_id", null: false
    t.string "nonce", null: false
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_comms_request_nonces_on_created_at"
    t.index ["service_connection_id", "nonce"], name: "index_comms_request_nonces_on_service_connection_id_and_nonce", unique: true
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

  create_table "conversation_drafts", force: :cascade do |t|
    t.bigint "chat_id", null: false
    t.text "content", default: "", null: false
    t.datetime "created_at", null: false
    t.bigint "revision", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["chat_id", "user_id"], name: "index_conversation_drafts_on_chat_id_and_user_id", unique: true
    t.index ["chat_id"], name: "index_conversation_drafts_on_chat_id"
    t.index ["user_id"], name: "index_conversation_drafts_on_user_id"
  end

  create_table "device_stream_batches", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "device_stream_session_id", null: false
    t.datetime "observed_at", null: false
    t.string "payload_digest", null: false
    t.jsonb "rr_ms", null: false
    t.bigint "sequence", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_device_stream_batches_on_created_at"
    t.index ["device_stream_session_id", "sequence"], name: "idx_on_device_stream_session_id_sequence_dbc9d30154", unique: true
    t.index ["device_stream_session_id"], name: "index_device_stream_batches_on_device_stream_session_id"
    t.index ["observed_at"], name: "index_device_stream_batches_on_observed_at"
    t.check_constraint "sequence >= 0", name: "device_batch_nonnegative_sequence"
  end

  create_table "device_stream_credentials", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "device_stream_id", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["device_stream_id"], name: "index_device_stream_credentials_on_device_stream_id"
    t.index ["token_digest"], name: "index_device_stream_credentials_on_token_digest", unique: true
  end

  create_table "device_stream_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "device_stream_id", null: false
    t.datetime "erased_at"
    t.string "session_uuid", null: false
    t.datetime "updated_at", null: false
    t.index ["device_stream_id", "session_uuid"], name: "idx_on_device_stream_id_session_uuid_f4387caf71", unique: true
    t.index ["device_stream_id"], name: "index_device_stream_sessions_on_device_stream_id"
  end

  create_table "device_streams", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.integer "batches_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.datetime "erased_at"
    t.string "name", null: false
    t.jsonb "reader_agent_ids", default: [], null: false
    t.jsonb "reader_user_ids", default: [], null: false
    t.string "stream_key", null: false
    t.bigint "subject_user_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_device_streams_on_account_id"
    t.index ["stream_key"], name: "index_device_streams_on_stream_key", unique: true
    t.index ["subject_user_id"], name: "index_device_streams_on_subject_user_id"
  end

  create_table "field_files", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "uploaded_by_type"
    t.bigint "uploaded_by_id"
    t.string "title", limit: 200, null: false
    t.text "note"
    t.datetime "discarded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "extracted_text"
    t.datetime "text_extracted_at"
    t.string "indexed_filename"
    t.virtual "search_vector", type: :tsvector, as: "((setweight(to_tsvector('simple'::regconfig, \"left\"(COALESCE((((((COALESCE(title, ''::character varying))::text || ' '::text) || (COALESCE(indexed_filename, ''::character varying))::text) || ' '::text) || translate((((COALESCE(title, ''::character varying))::text || ' '::text) || (COALESCE(indexed_filename, ''::character varying))::text), '._-/'::text, repeat(' '::text, 4))), ''::text), 1000)), 'A'::\"char\") || setweight(to_tsvector('simple'::regconfig, \"left\"(COALESCE(note, ''::text), 4000)), 'B'::\"char\")) || setweight(to_tsvector('simple'::regconfig,\nCASE\n    WHEN (octet_length(\"left\"(COALESCE(extracted_text, ''::text), 128000)) <= 128000) THEN \"left\"(COALESCE(extracted_text, ''::text), 128000)\n    WHEN (octet_length(\"left\"(COALESCE(extracted_text, ''::text), 121600)) <= 128000) THEN \"left\"(COALESCE(extracted_text, ''::text), 121600)\n    WHEN (octet_length(\"left\"(COALESCE(extracted_text, ''::text), 115200)) <= 128000) THEN \"left\"(COALESCE(extracted_text, ''::text), 115200)\n    WHEN (octet_length(\"left\"(COALESCE(extracted_text, ''::text), 102400)) <= 128000) THEN \"left\"(COALESCE(extracted_text, ''::text), 102400)\n    WHEN (octet_length(\"left\"(COALESCE(extracted_text, ''::text), 89600)) <= 128000) THEN \"left\"(COALESCE(extracted_text, ''::text), 89600)\n    WHEN (octet_length(\"left\"(COALESCE(extracted_text, ''::text), 76800)) <= 128000) THEN \"left\"(COALESCE(extracted_text, ''::text), 76800)\n    WHEN (octet_length(\"left\"(COALESCE(extracted_text, ''::text), 64000)) <= 128000) THEN \"left\"(COALESCE(extracted_text, ''::text), 64000)\n    WHEN (octet_length(\"left\"(COALESCE(extracted_text, ''::text), 51200)) <= 128000) THEN \"left\"(COALESCE(extracted_text, ''::text), 51200)\n    WHEN (octet_length(\"left\"(COALESCE(extracted_text, ''::text), 42240)) <= 128000) THEN \"left\"(COALESCE(extracted_text, ''::text), 42240)\n    ELSE \"left\"(COALESCE(extracted_text, ''::text), 32000)\nEND), 'C'::\"char\"))", stored: true
    t.index ["account_id", "created_at"], name: "index_field_files_on_account_id_and_created_at"
    t.index ["account_id"], name: "index_field_files_on_account_id"
    t.index ["discarded_at"], name: "index_field_files_on_discarded_at"
    t.index ["search_vector"], name: "index_field_files_on_search_vector", using: :gin
    t.index ["uploaded_by_type", "uploaded_by_id"], name: "index_field_files_on_uploaded_by"
  end

  create_table "field_recording_dispatches", force: :cascade do |t|
    t.bigint "field_recording_id", null: false
    t.bigint "account_id", null: false
    t.bigint "audio_ms", null: false
    t.string "attempt_token", null: false
    t.string "request_id"
    t.string "transcription_id"
    t.string "outcome", default: "in_flight", null: false
    t.string "error"
    t.datetime "vendor_deleted_at"
    t.integer "vendor_delete_attempts", default: 0, null: false
    t.string "vendor_delete_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "created_at"], name: "index_field_recording_dispatches_on_account_id_and_created_at"
    t.index ["account_id"], name: "index_field_recording_dispatches_on_account_id"
    t.index ["attempt_token"], name: "index_field_recording_dispatches_on_attempt_token", unique: true
    t.index ["field_recording_id"], name: "index_field_recording_dispatches_on_field_recording_id"
    t.index ["request_id"], name: "index_field_recording_dispatches_on_request_id"
  end

  create_table "field_recording_identifications", force: :cascade do |t|
    t.bigint "field_recording_id", null: false
    t.string "vendor_job_id", null: false
    t.jsonb "snapshot", default: {}, null: false
    t.jsonb "speaker_decisions", default: {}, null: false
    t.string "status", default: "dispatched", null: false
    t.integer "poll_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["field_recording_id"], name: "index_field_recording_identifications_on_field_recording_id"
  end

  create_table "field_recording_reservations", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "field_recording_id", null: false
    t.bigint "audio_ms", null: false
    t.string "state", default: "pending", null: false
    t.datetime "reserved_at", null: false
    t.datetime "consumed_at"
    t.datetime "released_at"
    t.string "release_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "state", "consumed_at"], name: "index_field_recording_reservations_for_usage"
    t.index ["account_id"], name: "index_field_recording_reservations_on_account_id"
    t.index ["field_recording_id"], name: "index_field_recording_reservations_on_field_recording_id", unique: true
  end

  create_table "field_recording_speakers", force: :cascade do |t|
    t.bigint "field_recording_id", null: false
    t.string "label", null: false
    t.integer "position", null: false
    t.bigint "talk_ms", default: 0, null: false
    t.bigint "clip_start_ms"
    t.bigint "clip_end_ms"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "field_voice_id"
    t.string "naming_source"
    t.string "named_by_type"
    t.bigint "named_by_id"
    t.datetime "named_at"
    t.bigint "suggested_voice_id"
    t.string "suggested_name", limit: 100
    t.string "suggestion_quote", limit: 300
    t.bigint "suggestion_quote_ms"
    t.string "suggestion_source"
    t.datetime "suggested_at"
    t.integer "decision_generation", default: 0, null: false
    t.integer "suggestion_generation"
    t.bigint "recognised_voice_id"
    t.integer "recognition_confidence"
    t.bigint "recognition_print_generation"
    t.integer "recognition_decision_generation"
    t.index ["field_recording_id", "label"], name: "index_field_recording_speakers_on_field_recording_id_and_label", unique: true
    t.index ["field_recording_id"], name: "index_field_recording_speakers_on_field_recording_id"
    t.index ["field_voice_id"], name: "index_field_recording_speakers_on_field_voice_id"
    t.index ["named_by_type", "named_by_id"], name: "index_field_recording_speakers_on_named_by"
    t.index ["recognised_voice_id"], name: "index_field_recording_speakers_on_recognised_voice_id"
    t.index ["suggested_voice_id"], name: "index_field_recording_speakers_on_suggested_voice_id"
  end

  create_table "field_recordings", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "uploaded_by_type"
    t.bigint "uploaded_by_id"
    t.string "title", limit: 200, null: false
    t.text "note"
    t.integer "expected_speakers"
    t.bigint "duration_ms"
    t.string "status", default: "probing", null: false
    t.string "failure_reason"
    t.string "attempt_token"
    t.integer "dispatch_count", default: 0, null: false
    t.bigint "retried_from_id"
    t.datetime "ready_at"
    t.datetime "discarded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "transcript_words"
    t.text "transcript_text"
    t.string "language_code"
    t.string "suggestions_state"
    t.string "transcript_source", default: "vendor", null: false
    t.jsonb "transcript_turns"
    t.string "source_path", limit: 1000
    t.datetime "recorded_at"
    t.string "import_key", limit: 200
    t.virtual "search_vector", type: :tsvector, as: "((setweight(to_tsvector('simple'::regconfig, \"left\"(COALESCE((((COALESCE(title, ''::character varying))::text || ' '::text) || translate((COALESCE(title, ''::character varying))::text, '._-/'::text, repeat(' '::text, 4))), ''::text), 1000)), 'A'::\"char\") || setweight(to_tsvector('simple'::regconfig, \"left\"(COALESCE(note, ''::text), 4000)), 'B'::\"char\")) || setweight(to_tsvector('simple'::regconfig,\nCASE\n    WHEN (octet_length(\"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 128000)) <= 128000) THEN \"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 128000)\n    WHEN (octet_length(\"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 121600)) <= 128000) THEN \"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 121600)\n    WHEN (octet_length(\"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 115200)) <= 128000) THEN \"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 115200)\n    WHEN (octet_length(\"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 102400)) <= 128000) THEN \"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 102400)\n    WHEN (octet_length(\"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 89600)) <= 128000) THEN \"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 89600)\n    WHEN (octet_length(\"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 76800)) <= 128000) THEN \"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 76800)\n    WHEN (octet_length(\"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 64000)) <= 128000) THEN \"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 64000)\n    WHEN (octet_length(\"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 51200)) <= 128000) THEN \"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 51200)\n    WHEN (octet_length(\"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 42240)) <= 128000) THEN \"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 42240)\n    ELSE \"left\"(COALESCE(\n    CASE\n        WHEN ((status)::text = 'ready'::text) THEN transcript_text\n        ELSE NULL::text\n    END, ''::text), 32000)\nEND), 'C'::\"char\"))", stored: true
    t.index ["account_id", "created_at"], name: "index_field_recordings_on_account_id_and_created_at"
    t.index ["account_id", "import_key"], name: "index_field_recordings_on_account_id_and_import_key", unique: true, where: "(import_key IS NOT NULL)"
    t.index ["account_id"], name: "index_field_recordings_on_account_id"
    t.index ["discarded_at"], name: "index_field_recordings_on_discarded_at"
    t.index ["retried_from_id"], name: "index_field_recordings_on_retried_from_id"
    t.index ["search_vector"], name: "index_field_recordings_on_search_vector", using: :gin
    t.index ["status"], name: "index_field_recordings_on_status"
    t.index ["uploaded_by_type", "uploaded_by_id"], name: "index_field_recordings_on_uploaded_by"
  end

  create_table "field_taggings", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "field_tag_id", null: false
    t.string "taggable_type", null: false
    t.bigint "taggable_id", null: false
    t.string "tagged_by_type"
    t.bigint "tagged_by_id"
    t.datetime "discarded_at"
    t.string "discarded_by_type"
    t.bigint "discarded_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_field_taggings_on_account_id"
    t.index ["discarded_by_type", "discarded_by_id"], name: "index_field_taggings_on_discarded_by"
    t.index ["field_tag_id", "taggable_type", "taggable_id"], name: "index_field_taggings_on_kept_tag_and_item", unique: true, where: "(discarded_at IS NULL)"
    t.index ["field_tag_id"], name: "index_field_taggings_on_field_tag_id"
    t.index ["taggable_type", "taggable_id"], name: "index_field_taggings_on_taggable"
    t.index ["tagged_by_type", "tagged_by_id"], name: "index_field_taggings_on_tagged_by"
    t.check_constraint "taggable_type::text = ANY (ARRAY['FieldFile'::character varying, 'FieldRecording'::character varying, 'Whiteboard'::character varying]::text[])", name: "field_taggings_taggable_type"
  end

  create_table "field_tags", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "name", limit: 50, null: false
    t.string "created_by_type"
    t.bigint "created_by_id"
    t.datetime "discarded_at"
    t.string "discarded_by_type"
    t.bigint "discarded_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "name"], name: "index_field_tags_on_account_and_kept_name", unique: true, where: "(discarded_at IS NULL)"
    t.index ["account_id"], name: "index_field_tags_on_account_id"
    t.index ["created_by_type", "created_by_id"], name: "index_field_tags_on_created_by"
    t.index ["discarded_by_type", "discarded_by_id"], name: "index_field_tags_on_discarded_by"
  end

  create_table "field_voice_enrolments", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "field_voice_id", null: false
    t.bigint "field_recording_speaker_id", null: false
    t.bigint "start_generation", null: false
    t.integer "decision_generation", default: 0, null: false
    t.integer "sample_ms", null: false
    t.string "consented_by_type"
    t.bigint "consented_by_id"
    t.string "consent_text_version", null: false
    t.string "status", default: "previewing", null: false
    t.string "vendor_job_id"
    t.integer "poll_count", default: 0, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_field_voice_enrolments_on_account_id"
    t.index ["consented_by_type", "consented_by_id"], name: "index_field_voice_enrolments_on_consented_by"
    t.index ["field_recording_speaker_id"], name: "index_field_voice_enrolments_on_field_recording_speaker_id"
    t.index ["field_voice_id"], name: "index_field_voice_enrolments_on_field_voice_id"
  end

  create_table "field_voiceprints", force: :cascade do |t|
    t.bigint "field_voice_id", null: false
    t.bigint "account_id", null: false
    t.text "print", null: false
    t.bigint "generation", null: false
    t.bigint "sample_recording_id"
    t.integer "sample_ms", null: false
    t.string "consented_by_type"
    t.bigint "consented_by_id"
    t.datetime "consented_at", null: false
    t.string "consent_text_version", null: false
    t.string "vendor", default: "pyannote", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_field_voiceprints_on_account_id"
    t.index ["consented_by_type", "consented_by_id"], name: "index_field_voiceprints_on_consented_by"
    t.index ["field_voice_id"], name: "index_field_voiceprints_on_field_voice_id", unique: true
    t.index ["sample_recording_id"], name: "index_field_voiceprints_on_sample_recording_id"
  end

  create_table "field_voices", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "name", limit: 100, null: false
    t.bigint "user_id"
    t.string "created_by_type"
    t.bigint "created_by_id"
    t.datetime "discarded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "print_generation", default: 0, null: false
    t.index "account_id, lower((name)::text)", name: "index_field_voices_unique_kept_name", unique: true, where: "(discarded_at IS NULL)"
    t.index ["account_id", "user_id"], name: "index_field_voices_unique_kept_user", unique: true, where: "((discarded_at IS NULL) AND (user_id IS NOT NULL))"
    t.index ["account_id"], name: "index_field_voices_on_account_id"
    t.index ["created_by_type", "created_by_id"], name: "index_field_voices_on_created_by"
    t.index ["user_id"], name: "index_field_voices_on_user_id"
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

  create_table "github_resident_imports", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "service_connection_id", null: false
    t.bigint "requested_by_id", null: false
    t.bigint "approved_by_id"
    t.string "name", null: false
    t.string "model_id", null: false
    t.string "repository", null: false
    t.string "repository_id", null: false
    t.string "branch", null: false
    t.string "commit_sha", null: false
    t.string "portable_home_id", null: false
    t.string "credential_fingerprint", null: false
    t.jsonb "token_metadata", default: {}, null: false
    t.string "status", default: "pending_review", null: false
    t.string "approved_commit_sha"
    t.string "observed_branch_sha_at_approval"
    t.string "approved_credential_fingerprint"
    t.string "approved_image"
    t.datetime "approved_at"
    t.string "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "sync_strategy", default: "existing", null: false
    t.jsonb "sync_configuration", default: {}, null: false
    t.jsonb "sync_health", default: {}, null: false
    t.index ["account_id"], name: "index_github_resident_imports_on_account_id"
    t.index ["approved_by_id"], name: "index_github_resident_imports_on_approved_by_id"
    t.index ["requested_by_id"], name: "index_github_resident_imports_on_requested_by_id"
    t.index ["service_connection_id"], name: "index_github_resident_imports_on_service_connection_id"
    t.check_constraint "sync_strategy::text = ANY (ARRAY['existing'::character varying::text, 'standard'::character varying::text])", name: "github_resident_import_sync_strategy"
  end

  create_table "guest_memberships", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "agent_id", null: false
    t.bigint "added_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "agent_id"], name: "index_guest_memberships_on_account_id_and_agent_id", unique: true
    t.index ["account_id"], name: "index_guest_memberships_on_account_id"
    t.index ["added_by_id"], name: "index_guest_memberships_on_added_by_id"
    t.index ["agent_id"], name: "index_guest_memberships_on_agent_id"
  end

  create_table "house_inference_calls", force: :cascade do |t|
    t.decimal "charge_usd", precision: 14, scale: 8, null: false
    t.datetime "created_at", null: false
    t.bigint "house_inference_grant_id", null: false
    t.string "model_id", null: false
    t.date "month", null: false
    t.string "provider_route", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.string "upstream_id"
    t.index ["house_inference_grant_id", "month"], name: "index_house_calls_on_grant_month"
    t.index ["house_inference_grant_id"], name: "index_house_inference_calls_on_house_inference_grant_id"
    t.index ["month"], name: "index_house_inference_calls_on_month"
    t.check_constraint "charge_usd >= 0::numeric", name: "house_calls_nonnegative_charge"
  end

  create_table "house_inference_grants", force: :cascade do |t|
    t.bigint "agent_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["agent_id"], name: "index_house_inference_grants_on_agent_id", unique: true
    t.index ["user_id"], name: "index_house_inference_grants_on_user_id", unique: true
  end

  create_table "house_samples", force: :cascade do |t|
    t.string "kind", null: false
    t.string "subject", default: "", null: false
    t.bigint "agent_id"
    t.datetime "sampled_at", null: false
    t.jsonb "metrics", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "kind", "sampled_at"], name: "index_house_samples_on_agent_id_and_kind_and_sampled_at"
    t.index ["agent_id"], name: "index_house_samples_on_agent_id"
    t.index ["kind", "sampled_at"], name: "index_house_samples_on_kind_and_sampled_at"
    t.index ["kind", "subject", "sampled_at"], name: "index_house_samples_on_kind_and_subject_and_sampled_at"
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

  create_table "message_dispatches", force: :cascade do |t|
    t.datetime "accepted_at", null: false
    t.bigint "chat_id", null: false
    t.string "client_invocation_id"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "kind", default: "mention", null: false
    t.bigint "message_id"
    t.string "reason"
    t.string "request_digest"
    t.bigint "runtime_interaction_id"
    t.datetime "settled_at"
    t.string "status", default: "pending", null: false
    t.jsonb "target_agent_ids", default: [], null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["chat_id", "user_id", "client_invocation_id"], name: "index_message_dispatches_on_invocation_identity", unique: true, where: "(client_invocation_id IS NOT NULL)"
    t.index ["chat_id"], name: "index_message_dispatches_on_chat_id"
    t.index ["message_id"], name: "index_message_dispatches_on_message_id", unique: true
    t.index ["runtime_interaction_id"], name: "index_message_dispatches_on_runtime_interaction_id"
    t.index ["status", "accepted_at"], name: "index_message_dispatches_on_status_and_accepted_at"
    t.index ["user_id"], name: "index_message_dispatches_on_user_id"
    t.check_constraint "(kind::text = ANY (ARRAY['mention'::character varying::text, 'automatic'::character varying::text, 'rhythm'::character varying::text])) AND message_id IS NOT NULL AND client_invocation_id IS NULL AND request_digest IS NULL OR kind::text = 'invoke'::text AND message_id IS NULL AND client_invocation_id IS NOT NULL AND request_digest IS NOT NULL", name: "message_dispatches_kind_variant"
    t.check_constraint "user_id IS NOT NULL OR kind::text = 'rhythm'::text", name: "message_dispatches_human_author"
  end

  create_table "message_stone_revisions", force: :cascade do |t|
    t.bigint "message_id", null: false
    t.bigint "stone_revision_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id", "stone_revision_id"], name: "idx_on_message_id_stone_revision_id_c117e2b9a3", unique: true
    t.index ["message_id"], name: "index_message_stone_revisions_on_message_id"
    t.index ["stone_revision_id"], name: "index_message_stone_revisions_on_stone_revision_id"
  end

  create_table "messages", force: :cascade do |t|
    t.bigint "agent_id"
    t.bigint "ai_model_id"
    t.boolean "audio_source", default: false, null: false
    t.integer "cache_creation_tokens"
    t.integer "cached_tokens"
    t.bigint "chat_id", null: false
    t.string "client_message_id"
    t.text "content"
    t.datetime "created_at", null: false
    t.datetime "discarded_at"
    t.integer "envelope_prompt_bytes"
    t.integer "input_tokens"
    t.string "model_id_string"
    t.datetime "moderated_at"
    t.jsonb "moderation_scores"
    t.integer "output_tokens"
    t.boolean "progress_break_after", default: false, null: false
    t.boolean "progress_message", default: false, null: false
    t.integer "prompt_layout_version"
    t.string "reasoning_skip_reason"
    t.jsonb "replay_payload"
    t.bigint "revision", default: 0, null: false
    t.string "role", null: false
    t.bigint "runtime_interaction_id"
    t.integer "stable_prompt_bytes"
    t.string "stable_prompt_sha256"
    t.boolean "streaming", default: false, null: false
    t.string "submission_digest"
    t.text "thinking_text"
    t.integer "thinking_tokens"
    t.bigint "tool_call_id"
    t.string "tool_status"
    t.text "tools_used", default: [], array: true
    t.integer "transcript_prompt_bytes"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.boolean "reply_attention_pending", default: false, null: false
    t.bigint "safeguard_detection_id"
    t.index ["agent_id"], name: "index_messages_on_agent_id"
    t.index ["ai_model_id"], name: "index_messages_on_ai_model_id"
    t.index ["chat_id", "created_at"], name: "index_messages_on_chat_id_and_created_at"
    t.index ["chat_id", "id"], name: "index_messages_pending_reply_attention", where: "reply_attention_pending"
    t.index ["chat_id", "revision"], name: "index_messages_on_chat_id_and_revision"
    t.index ["chat_id", "user_id", "client_message_id"], name: "index_messages_on_client_message_identity", unique: true, where: "(client_message_id IS NOT NULL)"
    t.index ["chat_id"], name: "index_messages_on_chat_id"
    t.index ["discarded_at"], name: "index_messages_on_discarded_at"
    t.index ["reasoning_skip_reason"], name: "index_messages_on_reasoning_skip_reason", where: "(reasoning_skip_reason IS NOT NULL)"
    t.index ["runtime_interaction_id"], name: "index_messages_on_runtime_interaction_id"
    t.index ["safeguard_detection_id"], name: "index_messages_on_safeguard_detection_id", unique: true, where: "(safeguard_detection_id IS NOT NULL)"
    t.index ["streaming"], name: "index_messages_on_streaming"
    t.index ["tool_call_id"], name: "index_messages_on_tool_call_id"
    t.index ["tools_used"], name: "index_messages_on_tools_used", using: :gin
    t.index ["user_id"], name: "index_messages_on_user_id"
  end

  create_table "metered_action_events", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "action", null: false
    t.bigint "agent_id", null: false
    t.bigint "cost_in_usd_ticks"
    t.datetime "created_at", null: false
    t.string "outcome", default: "admitted", null: false
    t.datetime "outcome_recorded_at"
    t.string "provider"
    t.string "provider_request_id"
    t.string "request_id", null: false
    t.datetime "updated_at", null: false
    t.jsonb "usage", default: {}, null: false
    t.index ["account_id"], name: "index_metered_action_events_on_account_id"
    t.index ["action", "account_id", "created_at"], name: "idx_on_action_account_id_created_at_8885d8b84f"
    t.index ["action", "agent_id", "created_at"], name: "idx_on_action_agent_id_created_at_8b71c5f0ce"
    t.index ["agent_id"], name: "index_metered_action_events_on_agent_id"
    t.index ["request_id"], name: "index_metered_action_events_on_request_id", unique: true
  end

  create_table "mnemodyne_edges", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "edge_type", null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "source_id", null: false
    t.uuid "target_id", null: false
    t.datetime "updated_at", null: false
    t.uuid "vault_id", null: false
    t.float "weight", default: 0.5, null: false
    t.index ["vault_id", "source_id", "target_id", "edge_type"], name: "index_mnemodyne_edges_unique_per_vault", unique: true
    t.index ["vault_id", "target_id"], name: "index_mnemodyne_edges_on_vault_id_and_target_id"
    t.index ["vault_id"], name: "index_mnemodyne_edges_on_vault_id"
    t.check_constraint "jsonb_typeof(metadata) = 'object'::text", name: "mnemodyne_edge_metadata_object"
    t.check_constraint "source_id <> target_id", name: "mnemodyne_edge_no_self_loop"
    t.check_constraint "weight >= 0::double precision AND weight <= 1::double precision", name: "mnemodyne_edge_weight_range"
  end

  create_table "mnemodyne_nodes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.float "charge", default: 0.5, null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "disclosure", default: "never_automatic", null: false
    t.float "embedding", array: true
    t.string "embedding_digest"
    t.string "embedding_profile"
    t.string "integration_state", default: "raw", null: false
    t.boolean "is_dormant", default: false, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "node_type", null: false
    t.text "source_uris", default: [], null: false, array: true
    t.datetime "updated_at", null: false
    t.uuid "vault_id", null: false
    t.index "vault_id, node_type, lower(content)", name: "index_mnemodyne_hubs_unique_per_vault", unique: true, where: "((node_type)::text = ANY (ARRAY[('need'::character varying)::text, ('person'::character varying)::text]))"
    t.index ["vault_id", "id"], name: "index_mnemodyne_nodes_on_vault_id_and_id", unique: true
    t.index ["vault_id", "node_type"], name: "index_mnemodyne_nodes_on_vault_id_and_node_type"
    t.index ["vault_id"], name: "index_mnemodyne_nodes_on_vault_id"
    t.check_constraint "charge >= 0::double precision AND charge <= 1::double precision", name: "mnemodyne_node_charge_range"
    t.check_constraint "disclosure::text = ANY (ARRAY['automatic'::character varying::text, 'never_automatic'::character varying::text])", name: "mnemodyne_node_disclosure"
    t.check_constraint "integration_state::text = ANY (ARRAY['raw'::character varying::text, 'active'::character varying::text, 'integrated'::character varying::text, 'constitutional'::character varying::text])", name: "mnemodyne_node_integration_state"
    t.check_constraint "jsonb_typeof(metadata) = 'object'::text", name: "mnemodyne_node_metadata_object"
  end

  create_table "mnemodyne_operations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "request_digest", null: false
    t.jsonb "result", null: false
    t.datetime "updated_at", null: false
    t.uuid "vault_id", null: false
    t.index ["vault_id", "key"], name: "index_mnemodyne_operations_on_vault_id_and_key", unique: true
    t.index ["vault_id"], name: "index_mnemodyne_operations_on_vault_id"
  end

  create_table "mnemodyne_uses", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "delta", null: false
    t.datetime "expires_at", null: false
    t.uuid "node_id", null: false
    t.string "reason", null: false
    t.uuid "recall_id", null: false
    t.datetime "updated_at", null: false
    t.uuid "vault_id", null: false
    t.index ["vault_id", "recall_id", "node_id"], name: "index_mnemodyne_uses_on_vault_id_and_recall_id_and_node_id", unique: true
    t.index ["vault_id"], name: "index_mnemodyne_uses_on_vault_id"
  end

  create_table "mnemodyne_vaults", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.boolean "auto_preview_enabled", default: false, null: false
    t.float "charge_decay_floor", default: 0.1, null: false
    t.float "charge_decay_rate", default: 0.001, null: false
    t.datetime "created_at", null: false
    t.float "decay_rate", default: 0.005, null: false
    t.datetime "erase_after"
    t.boolean "erase_constitutional", default: false, null: false
    t.string "erasure_fingerprint"
    t.datetime "erasure_requested_at"
    t.datetime "last_automatic_recall_at"
    t.string "last_automatic_recall_status"
    t.date "last_decay_on"
    t.integer "recall_generation", default: 0, null: false
    t.datetime "suspended_at"
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_mnemodyne_vaults_on_agent_id", unique: true
    t.check_constraint "decay_rate >= 0::double precision AND decay_rate <= 1::double precision", name: "mnemodyne_decay_range"
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

  create_table "oauth_access_grants", force: :cascade do |t|
    t.bigint "application_id", null: false
    t.string "code_challenge"
    t.string "code_challenge_method"
    t.datetime "created_at", null: false
    t.string "device_label"
    t.integer "expires_in", null: false
    t.text "redirect_uri", null: false
    t.bigint "resource_owner_id", null: false
    t.datetime "revoked_at"
    t.string "scopes", default: "", null: false
    t.string "token", null: false
    t.index ["application_id"], name: "index_oauth_access_grants_on_application_id"
    t.index ["resource_owner_id"], name: "index_oauth_access_grants_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_grants_on_token", unique: true
  end

  create_table "oauth_access_tokens", force: :cascade do |t|
    t.bigint "app_session_id", null: false
    t.bigint "application_id", null: false
    t.datetime "created_at", null: false
    t.string "device_label"
    t.integer "expires_in"
    t.string "previous_refresh_token", default: "", null: false
    t.string "refresh_token"
    t.bigint "resource_owner_id", null: false
    t.datetime "revoked_at"
    t.string "scopes"
    t.string "token", null: false
    t.index ["app_session_id"], name: "index_oauth_access_tokens_on_app_session_id"
    t.index ["application_id"], name: "index_oauth_access_tokens_on_application_id"
    t.index ["refresh_token"], name: "index_oauth_access_tokens_on_refresh_token", unique: true
    t.index ["resource_owner_id"], name: "index_oauth_access_tokens_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_tokens_on_token", unique: true
  end

  create_table "oauth_applications", force: :cascade do |t|
    t.boolean "confidential", default: false, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.string "secret"
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.index ["uid"], name: "index_oauth_applications_on_uid", unique: true
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

  create_table "pending_wake_sources", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.bigint "message_id"
    t.bigint "pending_wake_id", null: false
    t.bigint "requester_agent_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["message_id"], name: "index_pending_wake_sources_on_message_id"
    t.index ["pending_wake_id"], name: "index_pending_wake_sources_on_pending_wake_id"
    t.index ["requester_agent_id"], name: "index_pending_wake_sources_on_requester_agent_id"
    t.index ["user_id"], name: "index_pending_wake_sources_on_user_id"
  end

  create_table "pending_wakes", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.bigint "chat_id", null: false
    t.datetime "created_at", null: false
    t.string "drop_reason"
    t.datetime "dropped_at"
    t.datetime "first_requested_at", null: false
    t.datetime "last_requested_at", null: false
    t.bigint "released_interaction_id"
    t.datetime "released_at"
    t.integer "requests_count", default: 1, null: false
    t.string "requested_by", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_pending_wakes_on_agent_id"
    t.index ["chat_id", "agent_id"], name: "index_pending_wakes_one_open_per_resident_room", unique: true, where: "((released_at IS NULL) AND (dropped_at IS NULL))"
    t.index ["chat_id"], name: "index_pending_wakes_on_chat_id"
    t.index ["released_interaction_id"], name: "index_pending_wakes_on_released_interaction_id"
  end

  create_table "profiles", force: :cascade do |t|
    t.string "chat_colour"
    t.datetime "created_at", null: false
    t.string "first_name"
    t.string "last_name"
    t.jsonb "preferences", default: {}
    t.string "theme", default: "system"
    t.integer "theme_hue"
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

  create_table "reply_dismissals", force: :cascade do |t|
    t.bigint "chat_id", null: false
    t.bigint "user_id", null: false
    t.bigint "through_message_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_id", "user_id"], name: "index_reply_dismissals_on_chat_id_and_user_id", unique: true
    t.index ["chat_id"], name: "index_reply_dismissals_on_chat_id"
    t.index ["user_id"], name: "index_reply_dismissals_on_user_id"
  end

  create_table "reply_expectations", force: :cascade do |t|
    t.bigint "message_id", null: false
    t.bigint "user_id", null: false
    t.bigint "answered_by_message_id"
    t.integer "state", default: 0, null: false
    t.float "score", null: false
    t.string "classifier_version", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["answered_by_message_id"], name: "index_reply_expectations_on_answered_by_message_id"
    t.index ["message_id", "user_id"], name: "index_reply_expectations_on_message_id_and_user_id", unique: true
    t.index ["message_id"], name: "index_reply_expectations_on_message_id"
    t.index ["user_id"], name: "index_open_reply_expectations_on_user", where: "(state = 0)"
    t.index ["user_id"], name: "index_reply_expectations_on_user_id"
    t.check_constraint "state = ANY (ARRAY[0, 1, 2])", name: "reply_expectation_state"
  end

  create_table "resident_turns", force: :cascade do |t|
    t.datetime "admitted_at"
    t.bigint "agent_id", null: false
    t.bigint "agent_runtime_interaction_id", null: false
    t.datetime "cancel_requested_at"
    t.datetime "checked_at"
    t.jsonb "completion_context", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "dispatch_id", null: false
    t.datetime "finished_at"
    t.string "ledger_id"
    t.text "payload", null: false
    t.datetime "poll_claimed_until"
    t.datetime "prepared_at"
    t.string "session_id", null: false
    t.string "state", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_resident_turns_on_agent_id"
    t.index ["agent_runtime_interaction_id"], name: "index_resident_turns_on_agent_runtime_interaction_id", unique: true
    t.index ["dispatch_id"], name: "index_resident_turns_on_dispatch_id", unique: true
    t.index ["session_id"], name: "one_admitted_resident_session", unique: true, where: "((state)::text = ANY (ARRAY[('starting'::character varying)::text, ('running'::character varying)::text, ('unknown'::character varying)::text]))"
    t.index ["state", "created_at"], name: "index_resident_turns_on_state_and_created_at"
  end

  create_table "rhythm_agents", force: :cascade do |t|
    t.bigint "rhythm_id", null: false
    t.bigint "agent_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "model_id"
    t.index ["agent_id"], name: "index_rhythm_agents_on_agent_id"
    t.index ["rhythm_id", "agent_id"], name: "index_rhythm_agents_on_rhythm_id_and_agent_id", unique: true
    t.index ["rhythm_id"], name: "index_rhythm_agents_on_rhythm_id"
  end

  create_table "rhythm_holds", force: :cascade do |t|
    t.bigint "rhythm_id", null: false
    t.string "kind", null: false
    t.bigint "user_id"
    t.bigint "agent_id"
    t.text "reason", null: false
    t.datetime "released_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_rhythm_holds_on_agent_id"
    t.index ["rhythm_id", "agent_id"], name: "index_rhythm_holds_one_open_agent", unique: true, where: "((released_at IS NULL) AND ((kind)::text = 'agent'::text))"
    t.index ["rhythm_id", "kind"], name: "index_rhythm_holds_one_open_system", unique: true, where: "((released_at IS NULL) AND ((kind)::text = 'system'::text))"
    t.index ["rhythm_id", "user_id"], name: "index_rhythm_holds_one_open_human", unique: true, where: "((released_at IS NULL) AND ((kind)::text = 'human'::text))"
    t.index ["rhythm_id"], name: "index_rhythm_holds_on_rhythm_id"
    t.index ["user_id"], name: "index_rhythm_holds_on_user_id"
  end

  create_table "rhythm_occurrences", force: :cascade do |t|
    t.bigint "rhythm_id"
    t.bigint "chat_id", null: false
    t.bigint "message_id", null: false
    t.bigint "creator_id"
    t.string "creator_label", null: false
    t.string "title", null: false
    t.string "rhythm_title", null: false
    t.text "opening", null: false
    t.datetime "scheduled_for", null: false
    t.boolean "manual", default: false, null: false
    t.string "request_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "creator_agent_id"
    t.index ["chat_id"], name: "index_rhythm_occurrences_on_chat_id"
    t.index ["creator_agent_id"], name: "index_rhythm_occurrences_on_creator_agent_id"
    t.index ["creator_id"], name: "index_rhythm_occurrences_on_creator_id"
    t.index ["message_id"], name: "index_rhythm_occurrences_on_message_id", unique: true
    t.index ["rhythm_id", "request_key"], name: "index_rhythm_occurrences_manual_identity", unique: true, where: "(manual = true)"
    t.index ["rhythm_id", "scheduled_for"], name: "index_rhythm_occurrences_scheduled_identity", unique: true, where: "(manual = false)"
    t.index ["rhythm_id"], name: "index_rhythm_occurrences_on_rhythm_id"
    t.check_constraint "creator_id IS NULL OR creator_agent_id IS NULL", name: "rhythm_occurrences_one_creator"
    t.check_constraint "manual = true AND request_key IS NOT NULL OR manual = false AND request_key IS NULL", name: "rhythm_occurrences_request_identity"
  end

  create_table "rhythms", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "creator_id"
    t.string "title", null: false
    t.boolean "append_date", default: true, null: false
    t.text "opening", null: false
    t.string "cadence", null: false
    t.string "time_of_day", null: false
    t.integer "weekday"
    t.integer "month_day"
    t.integer "month"
    t.string "timezone", null: false
    t.datetime "next_run_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "creator_agent_id"
    t.index ["account_id"], name: "index_rhythms_on_account_id"
    t.index ["creator_agent_id"], name: "index_rhythms_on_creator_agent_id"
    t.index ["creator_id"], name: "index_rhythms_on_creator_id"
    t.index ["next_run_at"], name: "index_rhythms_on_next_run_at"
    t.check_constraint "creator_id IS NULL OR creator_agent_id IS NULL", name: "rhythms_one_creator"
  end

  create_table "runner_commands", force: :cascade do |t|
    t.string "public_id", null: false
    t.bigint "runner_enrollment_id", null: false
    t.bigint "agent_placement_id", null: false
    t.integer "generation", null: false
    t.string "kind", null: false
    t.text "payload_json"
    t.string "state", default: "queued", null: false
    t.integer "delivery_count", default: 0, null: false
    t.datetime "delivered_at"
    t.jsonb "result"
    t.datetime "finished_at"
    t.bigint "resident_turn_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_placement_id"], name: "index_runner_commands_on_agent_placement_id"
    t.index ["public_id"], name: "index_runner_commands_on_public_id", unique: true
    t.index ["resident_turn_id"], name: "index_runner_commands_on_resident_turn_id"
    t.index ["runner_enrollment_id", "state", "id"], name: "index_runner_commands_on_runner_enrollment_id_and_state_and_id"
    t.index ["runner_enrollment_id"], name: "index_runner_commands_on_runner_enrollment_id"
  end

  create_table "runner_enrollments", force: :cascade do |t|
    t.bigint "agent_placement_id", null: false
    t.bigint "procurement_operation_id"
    t.string "public_id", null: false
    t.string "token_digest", null: false
    t.datetime "expires_at", null: false
    t.bigint "expected_provider_server_id"
    t.string "public_key"
    t.datetime "enrolled_at"
    t.datetime "last_heartbeat_at"
    t.jsonb "last_facts", default: {}, null: false
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_placement_id"], name: "index_runner_enrollments_on_agent_placement_id"
    t.index ["procurement_operation_id"], name: "index_runner_enrollments_on_procurement_operation_id", unique: true, where: "(procurement_operation_id IS NOT NULL)"
    t.index ["public_id"], name: "index_runner_enrollments_on_public_id", unique: true
    t.index ["token_digest"], name: "index_runner_enrollments_on_token_digest", unique: true
    t.check_constraint "expected_provider_server_id > 0", name: "runner_enrollments_positive_server_id"
  end

  create_table "runner_request_nonces", force: :cascade do |t|
    t.bigint "runner_enrollment_id", null: false
    t.string "nonce", null: false
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_runner_request_nonces_on_created_at"
    t.index ["runner_enrollment_id", "nonce"], name: "index_runner_request_nonces_on_runner_enrollment_id_and_nonce", unique: true
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
    t.datetime "notice_acknowledged_at"
    t.index ["agent_id", "created_at"], name: "index_safeguard_detections_on_agent_id_and_created_at"
    t.index ["agent_id"], name: "index_safeguard_detections_on_agent_id"
    t.index ["agent_runtime_interaction_id"], name: "index_safeguard_detections_on_agent_runtime_interaction_id"
    t.index ["channel", "notice_acknowledged_at"], name: "index_safeguard_detections_outstanding", where: "((notice_acknowledged_at IS NULL) AND (reclaimed_at IS NULL))"
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
    t.text "pairing_qr"
    t.datetime "pairing_qr_expires_at"
    t.datetime "pairing_qr_issued_at"
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
    t.integer "max_accounts", default: 30, null: false
    t.integer "resident_turn_limit", default: 50, null: false
    t.integer "safeguard_owner_notice_threshold", default: 1, null: false
    t.boolean "show_usage_in_chat", default: false, null: false
    t.string "site_name", default: "souls.house", null: false
    t.datetime "updated_at", null: false
    t.string "follow_through_scope", default: "off", null: false
    t.boolean "safeguard_conversations_enabled", default: false, null: false
    t.boolean "new_residents_on_vm", default: false, null: false
    t.integer "vm_resident_limit", default: 0, null: false
  end

  create_table "stone_revisions", force: :cascade do |t|
    t.bigint "stone_id", null: false
    t.integer "number", null: false
    t.string "title", null: false
    t.bigint "user_id"
    t.bigint "agent_id"
    t.string "policy_version", null: false
    t.string "preview_status", default: "not_requested", null: false
    t.text "preview_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_stone_revisions_on_agent_id"
    t.index ["stone_id", "number"], name: "index_stone_revisions_on_stone_id_and_number", unique: true
    t.index ["stone_id"], name: "index_stone_revisions_on_stone_id"
    t.index ["user_id"], name: "index_stone_revisions_on_user_id"
    t.check_constraint "(user_id IS NULL) <> (agent_id IS NULL)", name: "stone_revisions_one_author"
    t.check_constraint "number > 0", name: "stone_revisions_positive_number"
  end

  create_table "stones", force: :cascade do |t|
    t.bigint "chat_id", null: false
    t.datetime "withdrawn_at"
    t.string "public_token", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_id"], name: "index_stones_on_chat_id"
    t.index ["public_token"], name: "index_stones_on_public_token", unique: true
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

  create_table "transcription_glossary_terms", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "term", null: false
    t.string "normalized_term", null: false
    t.string "source", default: "manual", null: false
    t.boolean "pinned", default: false, null: false
    t.datetime "suppressed_at"
    t.integer "sightings_count", default: 0, null: false
    t.datetime "last_seen_at"
    t.bigint "created_by_user_id"
    t.bigint "created_by_agent_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "normalized_term"], name: "idx_on_account_id_normalized_term_19331d33d5", unique: true
    t.index ["account_id"], name: "index_transcription_glossary_terms_on_account_id"
    t.index ["created_by_agent_id"], name: "index_transcription_glossary_terms_on_created_by_agent_id"
    t.index ["created_by_user_id"], name: "index_transcription_glossary_terms_on_created_by_user_id"
    t.check_constraint "source::text = ANY (ARRAY['manual'::character varying::text, 'correction'::character varying::text, 'harvested'::character varying::text])", name: "transcription_glossary_terms_source"
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
    t.bigint "default_account_id"
    t.datetime "field_you_hint_dismissed_at"
    t.index ["default_account_id"], name: "index_users_on_default_account_id"
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.index ["password_reset_token"], name: "index_users_on_password_reset_token", unique: true
  end

  create_table "versions", force: :cascade do |t|
    t.string "item_type", null: false
    t.bigint "item_id", null: false
    t.string "event", null: false
    t.string "whodunnit"
    t.jsonb "object"
    t.jsonb "object_changes"
    t.datetime "created_at"
    t.index ["item_type", "item_id", "created_at"], name: "index_versions_on_item_type_and_item_id_and_created_at"
  end

  create_table "visual_tags", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "label", limit: 80, null: false
    t.string "icon", null: false
    t.string "colour", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "pinned", default: false, null: false
    t.index ["account_id"], name: "index_visual_tags_on_account_id"
    t.index ["account_id"], name: "index_visual_tags_on_account_id_pinned", unique: true, where: "pinned"
    t.index ["id", "account_id"], name: "index_visual_tags_on_id_and_account_id", unique: true
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
    t.virtual "search_vector", type: :tsvector, as: "((setweight(to_tsvector('simple'::regconfig, \"left\"(COALESCE((((COALESCE(name, ''::character varying))::text || ' '::text) || translate((COALESCE(name, ''::character varying))::text, '._-/'::text, repeat(' '::text, 4))), ''::text), 1000)), 'A'::\"char\") || setweight(to_tsvector('simple'::regconfig, \"left\"((COALESCE(summary, ''::character varying))::text, 4000)), 'B'::\"char\")) || setweight(to_tsvector('simple'::regconfig,\nCASE\n    WHEN (octet_length(\"left\"(COALESCE(content, ''::text), 128000)) <= 128000) THEN \"left\"(COALESCE(content, ''::text), 128000)\n    WHEN (octet_length(\"left\"(COALESCE(content, ''::text), 121600)) <= 128000) THEN \"left\"(COALESCE(content, ''::text), 121600)\n    WHEN (octet_length(\"left\"(COALESCE(content, ''::text), 115200)) <= 128000) THEN \"left\"(COALESCE(content, ''::text), 115200)\n    WHEN (octet_length(\"left\"(COALESCE(content, ''::text), 102400)) <= 128000) THEN \"left\"(COALESCE(content, ''::text), 102400)\n    WHEN (octet_length(\"left\"(COALESCE(content, ''::text), 89600)) <= 128000) THEN \"left\"(COALESCE(content, ''::text), 89600)\n    WHEN (octet_length(\"left\"(COALESCE(content, ''::text), 76800)) <= 128000) THEN \"left\"(COALESCE(content, ''::text), 76800)\n    WHEN (octet_length(\"left\"(COALESCE(content, ''::text), 64000)) <= 128000) THEN \"left\"(COALESCE(content, ''::text), 64000)\n    WHEN (octet_length(\"left\"(COALESCE(content, ''::text), 51200)) <= 128000) THEN \"left\"(COALESCE(content, ''::text), 51200)\n    WHEN (octet_length(\"left\"(COALESCE(content, ''::text), 42240)) <= 128000) THEN \"left\"(COALESCE(content, ''::text), 42240)\n    ELSE \"left\"(COALESCE(content, ''::text), 32000)\nEND), 'C'::\"char\"))", stored: true
    t.index ["account_id", "deleted_at"], name: "index_whiteboards_on_account_id_and_deleted_at"
    t.index ["account_id", "name"], name: "index_whiteboards_on_account_id_and_name", unique: true, where: "(deleted_at IS NULL)"
    t.index ["account_id"], name: "index_whiteboards_on_account_id"
    t.index ["last_edited_by_type", "last_edited_by_id"], name: "index_whiteboards_on_last_edited_by"
    t.index ["search_vector"], name: "index_whiteboards_on_search_vector", using: :gin
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
  add_foreign_key "agent_bookmarks", "chat_agents", on_delete: :cascade
  add_foreign_key "agent_memories", "agents"
  add_foreign_key "agent_placements", "agents"
  add_foreign_key "agent_runtime_attempts", "agent_runtime_interactions"
  add_foreign_key "agent_runtime_events", "agent_runtime_attempts"
  add_foreign_key "agent_runtime_interactions", "agent_runtime_interactions", column: "follow_through_of_id", on_delete: :nullify
  add_foreign_key "agent_runtime_interactions", "agents"
  add_foreign_key "agent_runtime_interactions", "chats"
  add_foreign_key "agent_runtime_interactions", "message_dispatches", on_delete: :nullify
  add_foreign_key "agent_service_accesses", "agents"
  add_foreign_key "agent_service_accesses", "service_connections"
  add_foreign_key "agents", "accounts"
  add_foreign_key "agents", "api_keys", column: "outbound_api_key_id"
  add_foreign_key "agents", "github_resident_imports"
  add_foreign_key "api_key_requests", "api_keys"
  add_foreign_key "api_keys", "accounts"
  add_foreign_key "api_keys", "agents"
  add_foreign_key "api_keys", "users"
  add_foreign_key "app_cable_tickets", "app_sessions"
  add_foreign_key "app_sessions", "oauth_applications"
  add_foreign_key "app_sessions", "users"
  add_foreign_key "audit_logs", "accounts"
  add_foreign_key "audit_logs", "users"
  add_foreign_key "chat_agents", "agents"
  add_foreign_key "chat_agents", "chats"
  add_foreign_key "chats", "accounts"
  add_foreign_key "chats", "agents", column: "initiated_by_agent_id"
  add_foreign_key "chats", "ai_models"
  add_foreign_key "chats", "visual_tags", column: ["visual_tag_id", "account_id"], primary_key: ["id", "account_id"]
  add_foreign_key "chats", "whiteboards", column: "active_whiteboard_id"
  add_foreign_key "cloud_procurement_operations", "agent_placements"
  add_foreign_key "cloud_procurement_operations", "users", column: "requested_by_id"
  add_foreign_key "comms_chats", "service_connections"
  add_foreign_key "comms_messages", "comms_chats"
  add_foreign_key "comms_messages", "service_connections"
  add_foreign_key "comms_request_nonces", "service_connections", on_delete: :cascade
  add_foreign_key "conversation_compactions", "chats"
  add_foreign_key "conversation_drafts", "chats"
  add_foreign_key "conversation_drafts", "users"
  add_foreign_key "device_stream_batches", "device_stream_sessions"
  add_foreign_key "device_stream_credentials", "device_streams"
  add_foreign_key "device_stream_sessions", "device_streams"
  add_foreign_key "device_streams", "accounts"
  add_foreign_key "device_streams", "users", column: "subject_user_id"
  add_foreign_key "field_files", "accounts"
  add_foreign_key "field_recording_dispatches", "accounts"
  add_foreign_key "field_recording_dispatches", "field_recordings"
  add_foreign_key "field_recording_identifications", "field_recordings"
  add_foreign_key "field_recording_reservations", "accounts"
  add_foreign_key "field_recording_reservations", "field_recordings"
  add_foreign_key "field_recording_speakers", "field_recordings"
  add_foreign_key "field_recording_speakers", "field_voices"
  add_foreign_key "field_recording_speakers", "field_voices", column: "recognised_voice_id", on_delete: :nullify
  add_foreign_key "field_recording_speakers", "field_voices", column: "suggested_voice_id", on_delete: :nullify
  add_foreign_key "field_recordings", "accounts"
  add_foreign_key "field_recordings", "field_recordings", column: "retried_from_id", on_delete: :nullify
  add_foreign_key "field_taggings", "accounts"
  add_foreign_key "field_taggings", "field_tags"
  add_foreign_key "field_tags", "accounts"
  add_foreign_key "field_voice_enrolments", "accounts"
  add_foreign_key "field_voice_enrolments", "field_recording_speakers"
  add_foreign_key "field_voice_enrolments", "field_voices"
  add_foreign_key "field_voiceprints", "accounts"
  add_foreign_key "field_voiceprints", "field_recordings", column: "sample_recording_id", on_delete: :nullify
  add_foreign_key "field_voiceprints", "field_voices"
  add_foreign_key "field_voices", "accounts"
  add_foreign_key "field_voices", "users", on_delete: :nullify
  add_foreign_key "github_integrations", "accounts"
  add_foreign_key "github_resident_imports", "accounts"
  add_foreign_key "github_resident_imports", "service_connections"
  add_foreign_key "github_resident_imports", "users", column: "approved_by_id"
  add_foreign_key "github_resident_imports", "users", column: "requested_by_id"
  add_foreign_key "guest_memberships", "accounts", on_delete: :cascade
  add_foreign_key "guest_memberships", "agents", on_delete: :cascade
  add_foreign_key "guest_memberships", "users", column: "added_by_id", on_delete: :nullify
  add_foreign_key "house_inference_calls", "house_inference_grants"
  add_foreign_key "house_inference_grants", "agents"
  add_foreign_key "house_inference_grants", "users"
  add_foreign_key "house_samples", "agents", on_delete: :cascade
  add_foreign_key "memberships", "accounts"
  add_foreign_key "memberships", "users"
  add_foreign_key "memberships", "users", column: "invited_by_id"
  add_foreign_key "message_dispatches", "agent_runtime_interactions", column: "runtime_interaction_id", on_delete: :nullify
  add_foreign_key "message_dispatches", "chats"
  add_foreign_key "message_dispatches", "messages", on_delete: :cascade
  add_foreign_key "message_dispatches", "users"
  add_foreign_key "message_stone_revisions", "messages", on_delete: :cascade
  add_foreign_key "message_stone_revisions", "stone_revisions", on_delete: :cascade
  add_foreign_key "messages", "agent_runtime_interactions", column: "runtime_interaction_id"
  add_foreign_key "messages", "agents"
  add_foreign_key "messages", "ai_models"
  add_foreign_key "messages", "chats"
  add_foreign_key "messages", "safeguard_detections"
  add_foreign_key "messages", "users"
  add_foreign_key "metered_action_events", "accounts"
  add_foreign_key "metered_action_events", "agents"
  add_foreign_key "mnemodyne_edges", "mnemodyne_nodes", column: ["vault_id", "source_id"], primary_key: ["vault_id", "id"], on_delete: :cascade
  add_foreign_key "mnemodyne_edges", "mnemodyne_nodes", column: ["vault_id", "target_id"], primary_key: ["vault_id", "id"], on_delete: :cascade
  add_foreign_key "mnemodyne_edges", "mnemodyne_vaults", column: "vault_id"
  add_foreign_key "mnemodyne_nodes", "mnemodyne_vaults", column: "vault_id"
  add_foreign_key "mnemodyne_operations", "mnemodyne_vaults", column: "vault_id"
  add_foreign_key "mnemodyne_uses", "mnemodyne_nodes", column: ["vault_id", "node_id"], primary_key: ["vault_id", "id"], on_delete: :cascade
  add_foreign_key "mnemodyne_uses", "mnemodyne_vaults", column: "vault_id"
  add_foreign_key "mnemodyne_vaults", "agents"
  add_foreign_key "notices", "accounts"
  add_foreign_key "notices", "users", column: "created_by_id"
  add_foreign_key "oauth_access_grants", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_grants", "users", column: "resource_owner_id"
  add_foreign_key "oauth_access_tokens", "app_sessions"
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_tokens", "users", column: "resource_owner_id"
  add_foreign_key "oura_integrations", "users"
  add_foreign_key "pending_wake_sources", "agents", column: "requester_agent_id", on_delete: :nullify
  add_foreign_key "pending_wake_sources", "messages", on_delete: :cascade
  add_foreign_key "pending_wake_sources", "pending_wakes", on_delete: :cascade
  add_foreign_key "pending_wake_sources", "users", on_delete: :nullify
  add_foreign_key "pending_wakes", "agent_runtime_interactions", column: "released_interaction_id", on_delete: :nullify
  add_foreign_key "pending_wakes", "agents", on_delete: :cascade
  add_foreign_key "pending_wakes", "chats", on_delete: :cascade
  add_foreign_key "profiles", "users"
  add_foreign_key "prompt_outputs", "accounts"
  add_foreign_key "reply_dismissals", "chats", on_delete: :cascade
  add_foreign_key "reply_dismissals", "users", on_delete: :cascade
  add_foreign_key "reply_expectations", "messages", column: "answered_by_message_id", on_delete: :nullify
  add_foreign_key "reply_expectations", "messages", on_delete: :cascade
  add_foreign_key "reply_expectations", "users", on_delete: :cascade
  add_foreign_key "resident_turns", "agent_runtime_interactions"
  add_foreign_key "resident_turns", "agents"
  add_foreign_key "rhythm_agents", "agents", on_delete: :cascade
  add_foreign_key "rhythm_agents", "rhythms", on_delete: :cascade
  add_foreign_key "rhythm_holds", "agents", on_delete: :nullify
  add_foreign_key "rhythm_holds", "rhythms", on_delete: :cascade
  add_foreign_key "rhythm_holds", "users", on_delete: :nullify
  add_foreign_key "rhythm_occurrences", "agents", column: "creator_agent_id", on_delete: :nullify
  add_foreign_key "rhythm_occurrences", "chats", on_delete: :cascade
  add_foreign_key "rhythm_occurrences", "messages", on_delete: :cascade
  add_foreign_key "rhythm_occurrences", "rhythms", on_delete: :nullify
  add_foreign_key "rhythm_occurrences", "users", column: "creator_id", on_delete: :nullify
  add_foreign_key "rhythms", "accounts", on_delete: :cascade
  add_foreign_key "rhythms", "agents", column: "creator_agent_id", on_delete: :nullify
  add_foreign_key "rhythms", "users", column: "creator_id", on_delete: :nullify
  add_foreign_key "runner_commands", "agent_placements"
  add_foreign_key "runner_commands", "resident_turns"
  add_foreign_key "runner_commands", "runner_enrollments"
  add_foreign_key "runner_enrollments", "agent_placements"
  add_foreign_key "runner_enrollments", "cloud_procurement_operations", column: "procurement_operation_id"
  add_foreign_key "runner_request_nonces", "runner_enrollments", on_delete: :cascade
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
  add_foreign_key "stone_revisions", "agents"
  add_foreign_key "stone_revisions", "stones", on_delete: :cascade
  add_foreign_key "stone_revisions", "users"
  add_foreign_key "stones", "chats", on_delete: :cascade
  add_foreign_key "telegram_messages", "telegram_subscriptions"
  add_foreign_key "telegram_subscriptions", "agents"
  add_foreign_key "telegram_subscriptions", "safeguard_detections", column: "pending_safeguard_detection_id", on_delete: :nullify
  add_foreign_key "telegram_subscriptions", "users"
  add_foreign_key "tool_calls", "messages"
  add_foreign_key "transcription_glossary_terms", "accounts"
  add_foreign_key "transcription_glossary_terms", "agents", column: "created_by_agent_id", on_delete: :nullify
  add_foreign_key "transcription_glossary_terms", "users", column: "created_by_user_id", on_delete: :nullify
  add_foreign_key "tweet_logs", "agents"
  add_foreign_key "tweet_logs", "x_integrations"
  add_foreign_key "users", "accounts", column: "default_account_id", on_delete: :nullify
  add_foreign_key "visual_tags", "accounts"
  add_foreign_key "whiteboards", "accounts"
  add_foreign_key "x_integrations", "accounts"
end
