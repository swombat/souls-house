-- Chaos PostgreSQL migrations var/proc/db/migrate/postgres 0001-0038 at
-- seuros/chaos 058f14a4, concatenated verbatim, for
-- test/host_runner/oauth_store_merge_test.py. Regenerate when Chaos adds a migration.

-- ==== 0001_bigbang.sql
-- Let there be a runtime database.
-- PostgreSQL edition: use native types and trigger machinery where it helps.

CREATE TABLE processes (
    id TEXT PRIMARY KEY NOT NULL,
    parent_process_id TEXT REFERENCES processes(id) ON DELETE RESTRICT,
    fork_at_seq BIGINT,
    source TEXT NOT NULL,
    source_json JSONB NOT NULL,
    model_provider TEXT NOT NULL DEFAULT 'unknown',
    cwd TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    archived_at BIGINT,
    title TEXT NOT NULL DEFAULT '',
    sandbox_policy TEXT NOT NULL DEFAULT '',
    approval_mode TEXT NOT NULL DEFAULT '',
    tokens_used BIGINT NOT NULL DEFAULT 0,
    first_user_message TEXT NOT NULL DEFAULT '',
    cli_version TEXT NOT NULL DEFAULT '',
    agent_nickname TEXT,
    agent_role TEXT,
    git_sha TEXT,
    git_branch TEXT,
    git_origin_url TEXT,
    memory_mode TEXT NOT NULL DEFAULT 'enabled',
    model TEXT,
    reasoning_effort TEXT,
    agent_path TEXT,
    process_name TEXT,
    CHECK (parent_process_id IS NULL OR parent_process_id <> id),
    CHECK (
        (parent_process_id IS NULL AND fork_at_seq IS NULL)
        OR (parent_process_id IS NOT NULL AND fork_at_seq IS NOT NULL)
    )
);

CREATE INDEX idx_processes_created_at ON processes(created_at DESC, id DESC);
CREATE INDEX idx_processes_updated_at ON processes(updated_at DESC, id DESC);
CREATE INDEX idx_processes_archived_at ON processes(archived_at);
CREATE INDEX idx_processes_source ON processes(source);
CREATE INDEX idx_processes_provider ON processes(model_provider);
CREATE INDEX idx_processes_parent_process_id ON processes(parent_process_id);
CREATE INDEX idx_processes_git_branch ON processes(git_branch);
CREATE INDEX idx_processes_process_name ON processes(process_name);
CREATE INDEX idx_processes_active_updated_at
    ON processes(updated_at DESC, created_at DESC, id DESC)
    WHERE archived_at IS NULL;
CREATE INDEX idx_processes_archived_updated_at
    ON processes(archived_at DESC, updated_at DESC, id DESC)
    WHERE archived_at IS NOT NULL;

CREATE TABLE process_closure (
    ancestor_process_id TEXT NOT NULL REFERENCES processes(id) ON DELETE CASCADE,
    descendant_process_id TEXT NOT NULL REFERENCES processes(id) ON DELETE CASCADE,
    depth INTEGER NOT NULL,
    PRIMARY KEY (ancestor_process_id, descendant_process_id),
    CHECK (depth >= 0),
    CHECK (
        (ancestor_process_id = descendant_process_id AND depth = 0)
        OR (ancestor_process_id <> descendant_process_id AND depth > 0)
    )
);

CREATE INDEX idx_process_closure_ancestor_depth
    ON process_closure(ancestor_process_id, depth, descendant_process_id);
CREATE INDEX idx_process_closure_descendant_depth
    ON process_closure(descendant_process_id, depth, ancestor_process_id);

CREATE TABLE process_leases (
    process_id TEXT PRIMARY KEY NOT NULL REFERENCES processes(id) ON DELETE CASCADE,
    owner_id TEXT NOT NULL,
    lease_token TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    updated_at BIGINT NOT NULL
);

CREATE INDEX idx_process_leases_expires_at ON process_leases(expires_at);

CREATE TABLE journal_entries (
    process_id TEXT NOT NULL REFERENCES processes(id) ON DELETE CASCADE,
    seq BIGINT NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL,
    item_type TEXT NOT NULL,
    payload_json JSONB NOT NULL,
    PRIMARY KEY (process_id, seq)
);

CREATE INDEX idx_journal_entries_process_seq ON journal_entries(process_id, seq);

CREATE TABLE logs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts BIGINT NOT NULL,
    ts_nanos INTEGER NOT NULL,
    level TEXT NOT NULL,
    target TEXT NOT NULL,
    message TEXT,
    process_id TEXT,
    process_uuid TEXT,
    module_path TEXT,
    file TEXT,
    line INTEGER,
    estimated_bytes BIGINT NOT NULL DEFAULT 0
);

CREATE INDEX idx_logs_ts ON logs(ts DESC, ts_nanos DESC, id DESC);
CREATE INDEX idx_logs_process_id ON logs(process_id);
CREATE INDEX idx_logs_process_uuid ON logs(process_uuid);
CREATE INDEX idx_logs_process_id_ts ON logs(process_id, ts DESC, ts_nanos DESC, id DESC);
CREATE INDEX idx_logs_process_uuid_processless_ts
    ON logs(process_uuid, ts DESC, ts_nanos DESC, id DESC)
    WHERE process_id IS NULL;

CREATE TABLE process_dynamic_tools (
    process_id TEXT NOT NULL REFERENCES processes(id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    input_schema JSONB NOT NULL,
    defer_loading BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (process_id, position)
);

CREATE INDEX idx_process_dynamic_tools_thread ON process_dynamic_tools(process_id);

CREATE TABLE stage1_outputs (
    process_id TEXT PRIMARY KEY REFERENCES processes(id) ON DELETE CASCADE,
    source_updated_at BIGINT NOT NULL,
    raw_memory TEXT NOT NULL,
    rollout_summary TEXT NOT NULL,
    generated_at BIGINT NOT NULL,
    rollout_slug TEXT,
    usage_count BIGINT,
    last_usage BIGINT,
    selected_for_phase2 BOOLEAN NOT NULL DEFAULT FALSE,
    selected_for_phase2_source_updated_at BIGINT
);

CREATE INDEX idx_stage1_outputs_source_updated_at
    ON stage1_outputs(source_updated_at DESC, process_id DESC);

CREATE TABLE jobs (
    kind TEXT NOT NULL,
    job_key TEXT NOT NULL,
    status TEXT NOT NULL,
    worker_id TEXT,
    ownership_token TEXT,
    started_at BIGINT,
    finished_at BIGINT,
    lease_until BIGINT,
    retry_at BIGINT,
    retry_remaining INTEGER NOT NULL,
    last_error TEXT,
    input_watermark BIGINT,
    last_success_watermark BIGINT,
    PRIMARY KEY (kind, job_key)
);

CREATE INDEX idx_jobs_kind_status_retry_lease
    ON jobs(kind, status, retry_at, lease_until);

CREATE TABLE backfill_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    status TEXT NOT NULL,
    last_watermark TEXT,
    last_success_at BIGINT,
    updated_at BIGINT NOT NULL
);

INSERT INTO backfill_state (id, status, last_watermark, last_success_at, updated_at)
VALUES (1, 'pending', NULL, NULL, EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT);

CREATE TABLE agent_jobs (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    status TEXT NOT NULL,
    instruction TEXT NOT NULL,
    output_schema_json JSONB,
    input_headers_json JSONB NOT NULL,
    input_csv_path TEXT NOT NULL,
    output_csv_path TEXT NOT NULL,
    auto_export BOOLEAN NOT NULL DEFAULT TRUE,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    started_at BIGINT,
    completed_at BIGINT,
    last_error TEXT,
    max_runtime_seconds INTEGER
);

CREATE TABLE agent_job_items (
    job_id TEXT NOT NULL REFERENCES agent_jobs(id) ON DELETE CASCADE,
    item_id TEXT NOT NULL,
    row_index INTEGER NOT NULL,
    source_id TEXT,
    row_json JSONB NOT NULL,
    status TEXT NOT NULL,
    assigned_process_id TEXT,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    result_json JSONB,
    last_error TEXT,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    completed_at BIGINT,
    reported_at BIGINT,
    PRIMARY KEY (job_id, item_id)
);

CREATE INDEX idx_agent_jobs_status ON agent_jobs(status, updated_at DESC);
CREATE INDEX idx_agent_job_items_status ON agent_job_items(job_id, status, row_index ASC);

CREATE TABLE message_history (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    ts BIGINT NOT NULL,
    text TEXT NOT NULL,
    estimated_bytes BIGINT NOT NULL CHECK (estimated_bytes >= 0)
);

CREATE TABLE cron_jobs (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    schedule TEXT NOT NULL,
    command TEXT NOT NULL,
    scope TEXT NOT NULL DEFAULT 'project',
    project_path TEXT,
    session_id TEXT,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    last_run_at BIGINT,
    next_run_at BIGINT,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
);

CREATE INDEX idx_cron_jobs_scope ON cron_jobs(scope);
CREATE INDEX idx_cron_jobs_next_run ON cron_jobs(next_run_at) WHERE enabled = TRUE;
CREATE INDEX idx_cron_jobs_project ON cron_jobs(project_path) WHERE project_path IS NOT NULL;
CREATE INDEX idx_cron_jobs_session ON cron_jobs(session_id) WHERE session_id IS NOT NULL;

CREATE VIEW due_cron_jobs AS
    SELECT *
    FROM cron_jobs
    WHERE enabled = TRUE
      AND next_run_at IS NOT NULL
      AND next_run_at <= EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT
    ORDER BY next_run_at ASC;

CREATE TABLE model_catalog_cache (
    provider_name TEXT NOT NULL,
    wire_api TEXT NOT NULL,
    base_url TEXT NOT NULL,
    fetched_at BIGINT NOT NULL,
    etag TEXT,
    client_version TEXT,
    models_json JSONB NOT NULL,
    PRIMARY KEY (provider_name, wire_api, base_url)
);

CREATE INDEX idx_model_catalog_cache_fetched_at
    ON model_catalog_cache(fetched_at);

CREATE VIEW valid_model_cache AS
    SELECT *
    FROM model_catalog_cache
    WHERE fetched_at + 86400 >= EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT;

CREATE OR REPLACE FUNCTION chaos_touch_updated_at_epoch()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.updated_at = OLD.updated_at THEN
        NEW.updated_at := EXTRACT(EPOCH FROM clock_timestamp())::BIGINT;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION chaos_processes_enforce_lineage_immutability()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.parent_process_id IS DISTINCT FROM OLD.parent_process_id THEN
        RAISE EXCEPTION 'processes.parent_process_id is immutable';
    END IF;

    IF NEW.fork_at_seq IS DISTINCT FROM OLD.fork_at_seq THEN
        RAISE EXCEPTION 'processes.fork_at_seq is immutable';
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION chaos_processes_insert_closure()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        WITH RECURSIVE lineage_walk AS (
            SELECT
                np.id AS start_id,
                np.parent_process_id,
                ARRAY[np.id]::TEXT[] AS path
            FROM new_processes AS np
            WHERE np.parent_process_id IS NOT NULL

            UNION ALL

            SELECT
                lw.start_id,
                p.parent_process_id,
                lw.path || p.id
            FROM lineage_walk AS lw
            JOIN processes AS p
              ON p.id = lw.parent_process_id
            WHERE NOT p.id = ANY(lw.path)
        )
        SELECT 1
        FROM lineage_walk AS lw
        JOIN processes AS p
          ON p.id = lw.parent_process_id
        WHERE p.id = ANY(lw.path)
        LIMIT 1
    ) THEN
        RAISE EXCEPTION 'process lineage cannot contain cycles';
    END IF;

    INSERT INTO process_closure (
        ancestor_process_id,
        descendant_process_id,
        depth
    )
    WITH RECURSIVE lineage AS (
        SELECT
            np.id AS descendant_process_id,
            np.id AS ancestor_process_id,
            0::INTEGER AS depth,
            np.parent_process_id
        FROM new_processes AS np

        UNION ALL

        SELECT
            lineage.descendant_process_id,
            p.id AS ancestor_process_id,
            lineage.depth + 1,
            p.parent_process_id
        FROM lineage
        JOIN processes AS p
          ON p.id = lineage.parent_process_id
    )
    SELECT
        ancestor_process_id,
        descendant_process_id,
        depth
    FROM lineage
    ON CONFLICT DO NOTHING;

    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION chaos_raise_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'journal_entries is append-only';
END;
$$;

CREATE TRIGGER processes_touch
BEFORE UPDATE ON processes
FOR EACH ROW
EXECUTE FUNCTION chaos_touch_updated_at_epoch();

CREATE TRIGGER processes_lineage_immutable
BEFORE UPDATE ON processes
FOR EACH ROW
EXECUTE FUNCTION chaos_processes_enforce_lineage_immutability();

CREATE TRIGGER processes_insert_closure
AFTER INSERT ON processes
REFERENCING NEW TABLE AS new_processes
FOR EACH STATEMENT
EXECUTE FUNCTION chaos_processes_insert_closure();

CREATE TRIGGER process_leases_touch
BEFORE UPDATE ON process_leases
FOR EACH ROW
EXECUTE FUNCTION chaos_touch_updated_at_epoch();

CREATE TRIGGER agent_jobs_touch
BEFORE UPDATE ON agent_jobs
FOR EACH ROW
EXECUTE FUNCTION chaos_touch_updated_at_epoch();

CREATE TRIGGER agent_job_items_touch
BEFORE UPDATE ON agent_job_items
FOR EACH ROW
EXECUTE FUNCTION chaos_touch_updated_at_epoch();

CREATE TRIGGER cron_jobs_touch
BEFORE UPDATE ON cron_jobs
FOR EACH ROW
EXECUTE FUNCTION chaos_touch_updated_at_epoch();

CREATE TRIGGER journal_entries_no_update
BEFORE UPDATE ON journal_entries
FOR EACH ROW
EXECUTE FUNCTION chaos_raise_append_only();

CREATE TRIGGER journal_entries_no_delete
BEFORE DELETE ON journal_entries
FOR EACH ROW
EXECUTE FUNCTION chaos_raise_append_only();

CREATE VIEW active_processes AS
    SELECT *
    FROM processes
    WHERE archived_at IS NULL
    ORDER BY updated_at DESC, created_at DESC, id DESC;

CREATE VIEW archived_processes AS
    SELECT *
    FROM processes
    WHERE archived_at IS NOT NULL
    ORDER BY archived_at DESC, updated_at DESC, id DESC;

CREATE VIEW active_process_leases AS
    SELECT
        pl.process_id,
        pl.owner_id,
        pl.lease_token,
        pl.expires_at,
        pl.updated_at,
        p.source,
        p.title,
        p.cwd,
        p.model_provider
    FROM process_leases AS pl
    JOIN processes AS p ON p.id = pl.process_id
    WHERE p.archived_at IS NULL
      AND pl.expires_at > CURRENT_TIMESTAMP
    ORDER BY pl.expires_at ASC, pl.process_id ASC;

CREATE VIEW process_message_counts AS
    SELECT
        conversation_id AS process_id,
        COUNT(*) AS message_count,
        MAX(ts) AS last_message_ts,
        SUM(estimated_bytes) AS total_estimated_bytes
    FROM message_history
    GROUP BY conversation_id;

CREATE TABLE settings (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL,
    created_at BIGINT NOT NULL DEFAULT (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT),
    updated_at BIGINT NOT NULL DEFAULT (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT)
);

CREATE TRIGGER settings_touch
BEFORE UPDATE ON settings
FOR EACH ROW
EXECUTE FUNCTION chaos_touch_updated_at_epoch();

-- ==== 0002_ration.sql
-- Ration: rate-limit and usage snapshots sniffed from provider response
-- headers. ration_usage holds the latest reading per
-- (provider, base_url, label) so the TUI can render "85% left" without
-- an API round-trip. ration_history is append-only and never pruned —
-- this is a database, not a jsonl tail; keep every snapshot so trends
-- survive forever.
--
-- base_url disambiguates configs that share a provider tag but point at
-- different endpoints (two Anthropic accounts, a self-hosted
-- OpenAI-compatible proxy, a staging mirror): without it, their
-- snapshots would stomp each other under the same (provider, label)
-- identity.

CREATE TABLE ration_usage (
    provider TEXT NOT NULL,
    base_url TEXT NOT NULL,
    label TEXT NOT NULL,
    limit_value BIGINT,
    remaining BIGINT,
    utilization DOUBLE PRECISION NOT NULL,
    resets_at BIGINT,
    observed_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM clock_timestamp())::BIGINT,
    PRIMARY KEY (provider, base_url, label),
    CHECK (utilization >= 0.0 AND utilization <= 1.0),
    CHECK (limit_value IS NULL OR limit_value >= 0),
    CHECK (remaining IS NULL OR remaining >= 0)
);

CREATE INDEX idx_ration_usage_resets_at ON ration_usage(resets_at);

CREATE TRIGGER ration_usage_touch
BEFORE UPDATE ON ration_usage
FOR EACH ROW
EXECUTE FUNCTION chaos_touch_updated_at_epoch();

CREATE TABLE ration_history (
    id BIGSERIAL PRIMARY KEY,
    provider TEXT NOT NULL,
    base_url TEXT NOT NULL,
    label TEXT NOT NULL,
    limit_value BIGINT,
    remaining BIGINT,
    utilization DOUBLE PRECISION NOT NULL,
    resets_at BIGINT,
    observed_at BIGINT NOT NULL,
    CHECK (utilization >= 0.0 AND utilization <= 1.0),
    CHECK (limit_value IS NULL OR limit_value >= 0),
    CHECK (remaining IS NULL OR remaining >= 0)
);

CREATE INDEX idx_ration_history_provider_observed
    ON ration_history(provider, observed_at DESC, id DESC);
CREATE INDEX idx_ration_history_provider_base_label_observed
    ON ration_history(provider, base_url, label, observed_at DESC, id DESC);

-- ==== 0003_spool.sql
-- Spool: durable apprentice-job lifecycle.
--
-- payload_json holds a JSON array of caller-supplied custom_ids for traceability;
-- result_json holds Vec<(custom_id, TurnResult)>. batch_id is NULL until
-- the provider accepts submit.

CREATE TABLE spool_jobs (
    manifest_id    TEXT PRIMARY KEY,
    backend        TEXT NOT NULL,
    batch_id       TEXT,
    status         TEXT NOT NULL,
    request_count  INTEGER NOT NULL,
    payload_json   TEXT NOT NULL,
    result_json    TEXT,
    raw_result     TEXT,
    error          TEXT,
    submitted_at   BIGINT,
    completed_at   BIGINT,
    created_at     BIGINT NOT NULL,
    updated_at     BIGINT NOT NULL,
    CHECK (request_count >= 1)
);

CREATE INDEX idx_spool_jobs_status   ON spool_jobs(status);
CREATE INDEX idx_spool_jobs_batch_id ON spool_jobs(batch_id) WHERE batch_id IS NOT NULL;
CREATE INDEX idx_spool_jobs_backend  ON spool_jobs(backend);

ALTER TABLE cron_jobs ADD COLUMN kind        TEXT NOT NULL DEFAULT 'shell';
ALTER TABLE cron_jobs ADD COLUMN manifest_id TEXT;

CREATE INDEX idx_cron_jobs_kind        ON cron_jobs(kind);
CREATE INDEX idx_cron_jobs_manifest_id ON cron_jobs(manifest_id) WHERE manifest_id IS NOT NULL;

DROP VIEW IF EXISTS due_cron_jobs;
CREATE VIEW due_cron_jobs AS
    SELECT *
    FROM cron_jobs
    WHERE enabled = TRUE
      AND next_run_at IS NOT NULL
      AND next_run_at <= EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT
    ORDER BY next_run_at ASC;

-- spool_jobs updated_at trigger
CREATE OR REPLACE FUNCTION spool_jobs_touch_fn() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at THEN
        NEW.updated_at := EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER spool_jobs_touch
BEFORE UPDATE ON spool_jobs
FOR EACH ROW
EXECUTE FUNCTION spool_jobs_touch_fn();

-- ==== 0004_project_trust.sql
CREATE TABLE project_trust (
    project_path TEXT PRIMARY KEY NOT NULL,
    trust_level TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
);

CREATE INDEX idx_project_trust_updated_at
    ON project_trust(updated_at DESC);

-- ==== 0005_global_mcp_servers.sql
CREATE TABLE global_mcp_servers (
    name TEXT PRIMARY KEY NOT NULL,
    config_json JSONB NOT NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
);

CREATE INDEX idx_global_mcp_servers_updated_at
    ON global_mcp_servers(updated_at DESC);

-- ==== 0006_clamp_exchanges.sql
CREATE TABLE clamp_exchanges (
    id BIGSERIAL PRIMARY KEY,
    session_id TEXT,
    turn_id TEXT,
    created_at BIGINT NOT NULL,
    method TEXT NOT NULL,
    path TEXT NOT NULL,
    status INTEGER,
    headers_json JSONB NOT NULL,
    request_json JSONB,
    response_body TEXT,
    response_truncated BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_clamp_exchanges_created_at
    ON clamp_exchanges(created_at DESC);

CREATE INDEX idx_clamp_exchanges_session
    ON clamp_exchanges(session_id);

-- ==== 0007_journal_epoch_seconds.sql
-- Lease and journal timestamps are epoch seconds, like every other timestamp
-- column in this schema. Databases created before that alignment carry
-- TIMESTAMPTZ here; convert them in place.

DROP VIEW IF EXISTS active_process_leases;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'process_leases'
          AND column_name = 'expires_at'
          AND data_type <> 'bigint'
    ) THEN
        EXECUTE 'ALTER TABLE process_leases
                 ALTER COLUMN expires_at TYPE BIGINT
                 USING EXTRACT(EPOCH FROM expires_at)::BIGINT';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'journal_entries'
          AND column_name = 'recorded_at'
          AND data_type <> 'bigint'
    ) THEN
        EXECUTE 'ALTER TABLE journal_entries
                 ALTER COLUMN recorded_at TYPE BIGINT
                 USING EXTRACT(EPOCH FROM recorded_at)::BIGINT';
    END IF;
END
$$;

CREATE VIEW active_process_leases AS
    SELECT
        pl.process_id,
        pl.owner_id,
        pl.lease_token,
        pl.expires_at,
        pl.updated_at,
        p.source,
        p.title,
        p.cwd,
        p.model_provider
    FROM process_leases AS pl
    JOIN processes AS p ON p.id = pl.process_id
    WHERE p.archived_at IS NULL
      AND pl.expires_at > EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT
    ORDER BY pl.expires_at ASC, pl.process_id ASC;

-- ==== 0008_process_name_source.sql
ALTER TABLE processes ADD COLUMN process_name_source TEXT;

-- ==== 0009_reviewer_orchestration.sql
CREATE TABLE review_runs (
    id TEXT PRIMARY KEY NOT NULL,
    review_run_subject TEXT NOT NULL UNIQUE,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
);

CREATE TABLE reviewer_attempts (
    id TEXT PRIMARY KEY NOT NULL,
    run_id TEXT NOT NULL REFERENCES review_runs(id) ON DELETE CASCADE,
    ordinal BIGINT NOT NULL CHECK (ordinal >= 0),
    state TEXT NOT NULL CHECK (
        state IN (
            'selection',
            'spawn',
            'model_execution',
            'output_parse',
            'submission_unknown',
            'acknowledged',
            'cancelled',
            'terminal_failure'
        )
    ),
    provider_id TEXT NOT NULL,
    model TEXT NOT NULL,
    account_subject TEXT NOT NULL,
    model_family_subject TEXT NOT NULL,
    reviewer_attempt_subject TEXT NOT NULL UNIQUE,
    idempotency_key TEXT NOT NULL UNIQUE,
    prompt TEXT NOT NULL,
    mcp_server TEXT NOT NULL,
    mcp_tool TEXT NOT NULL,
    process_id TEXT,
    raw_output TEXT,
    submission_json JSONB,
    failure TEXT,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    completed_at BIGINT,
    UNIQUE (run_id, ordinal),
    UNIQUE (run_id, account_subject),
    UNIQUE (run_id, model_family_subject)
);

CREATE INDEX idx_reviewer_attempts_run_state
    ON reviewer_attempts(run_id, state, ordinal);

CREATE OR REPLACE FUNCTION chaos_reviewer_attempt_bindings_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF
        NEW.run_id IS DISTINCT FROM OLD.run_id
        OR NEW.ordinal IS DISTINCT FROM OLD.ordinal
        OR NEW.provider_id IS DISTINCT FROM OLD.provider_id
        OR NEW.model IS DISTINCT FROM OLD.model
        OR NEW.account_subject IS DISTINCT FROM OLD.account_subject
        OR NEW.model_family_subject IS DISTINCT FROM OLD.model_family_subject
        OR NEW.reviewer_attempt_subject IS DISTINCT FROM OLD.reviewer_attempt_subject
        OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
        OR NEW.prompt IS DISTINCT FROM OLD.prompt
        OR NEW.mcp_server IS DISTINCT FROM OLD.mcp_server
        OR NEW.mcp_tool IS DISTINCT FROM OLD.mcp_tool
        OR (OLD.process_id IS NOT NULL AND NEW.process_id IS DISTINCT FROM OLD.process_id)
        OR (OLD.raw_output IS NOT NULL AND NEW.raw_output IS DISTINCT FROM OLD.raw_output)
        OR (
            OLD.submission_json IS NOT NULL
            AND NEW.submission_json IS DISTINCT FROM OLD.submission_json
        )
    THEN
        RAISE EXCEPTION 'reviewer attempt binding is immutable';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER reviewer_attempts_bindings_immutable
BEFORE UPDATE ON reviewer_attempts
FOR EACH ROW
EXECUTE FUNCTION chaos_reviewer_attempt_bindings_immutable();

CREATE OR REPLACE FUNCTION chaos_review_run_identity_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'review run identity is immutable';
END;
$$;

CREATE TRIGGER review_runs_identity_immutable
BEFORE UPDATE OF id, review_run_subject ON review_runs
FOR EACH ROW
EXECUTE FUNCTION chaos_review_run_identity_immutable();

-- ==== 0010_review_run_owner.sql
ALTER TABLE review_runs
    ADD COLUMN owner_process_id TEXT;

UPDATE review_runs
SET owner_process_id = 'legacy-unowned'
WHERE owner_process_id IS NULL;

ALTER TABLE review_runs
    ALTER COLUMN owner_process_id SET NOT NULL;

DROP TRIGGER review_runs_identity_immutable ON review_runs;

CREATE TRIGGER review_runs_identity_immutable
BEFORE UPDATE OF id, review_run_subject, owner_process_id ON review_runs
FOR EACH ROW
EXECUTE FUNCTION chaos_review_run_identity_immutable();

-- ==== 0011_attested_review_process_identity.sql
CREATE UNIQUE INDEX processes_attested_review_attempt_unique
ON processes(parent_process_id, agent_role)
WHERE parent_process_id IS NOT NULL
  AND agent_role LIKE '__chaos_internal__:attested-review:%';

-- ==== 0012_backfill_process_previews.sql
-- Repair process metadata created before persisted role=user response items
-- participated in the process projection.
-- This is a repair, not session activity, so preserve updated_at ordering.
ALTER TABLE processes DISABLE TRIGGER processes_touch;

WITH raw_messages AS (
    SELECT
        p.id,
        COALESCE(
            (
                SELECT je.payload_json #>> '{payload,message}'
                FROM journal_entries AS je
                WHERE je.process_id = p.id
                  AND je.item_type = 'event_msg'
                  AND je.payload_json ->> 'type' = 'event_msg'
                  AND je.payload_json #>> '{payload,type}' = 'user_message'
                  AND btrim(je.payload_json #>> '{payload,message}') <> ''
                ORDER BY je.seq ASC
                LIMIT 1
            ),
            (
                SELECT content.value ->> 'text'
                FROM journal_entries AS je
                CROSS JOIN LATERAL jsonb_array_elements(
                    CASE
                        WHEN jsonb_typeof(je.payload_json #> '{payload,content}') = 'array'
                        THEN je.payload_json #> '{payload,content}'
                        ELSE '[]'::jsonb
                    END
                ) WITH ORDINALITY AS content(value, position)
                WHERE je.process_id = p.id
                  AND je.item_type = 'response_item'
                  AND je.payload_json ->> 'type' = 'response_item'
                  AND je.payload_json #>> '{payload,type}' = 'message'
                  AND je.payload_json #>> '{payload,role}' = 'user'
                  AND content.value ->> 'type' = 'input_text'
                  AND btrim(content.value ->> 'text') <> ''
                ORDER BY je.seq ASC, content.position ASC
                LIMIT 1
            )
        ) AS message
    FROM processes AS p
    WHERE btrim(p.first_user_message) = ''
       OR btrim(p.title) = ''
),
cleaned_messages AS (
    SELECT
        id,
        btrim(
            regexp_replace(
                regexp_replace(
                    message,
                    '^\s*(<environment_context>.*</environment_context>\s*)+',
                    '',
                    's'
                ),
                '^\s*## My request for [^:]+:\s*',
                ''
            )
        ) AS message
    FROM raw_messages
    WHERE message IS NOT NULL
)
UPDATE processes AS p
SET
    first_user_message = CASE
        WHEN btrim(p.first_user_message) = '' THEN cleaned.message
        ELSE p.first_user_message
    END,
    title = CASE
        WHEN btrim(p.title) = '' THEN cleaned.message
        ELSE p.title
    END
FROM cleaned_messages AS cleaned
WHERE p.id = cleaned.id
  AND cleaned.message <> '';

ALTER TABLE processes ENABLE TRIGGER processes_touch;

-- ==== 0013_retry_process_preview_backfill.sql
-- Migration 12 selected the first raw user item before removing injected
-- context. When that item contained only <environment_context>, cleanup made
-- it empty and the next real user message was never considered. Clean every
-- candidate first, then select the earliest non-empty result.
-- This is a repair, not session activity, so preserve updated_at ordering.
-- A transaction-local flag avoids ALTER TABLE ... DISABLE TRIGGER, which needs
-- an exclusive table lock and can deadlock with live journal writers.
CREATE OR REPLACE FUNCTION chaos_touch_updated_at_epoch()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.updated_at = OLD.updated_at
       AND COALESCE(current_setting('chaos.preserve_updated_at', true), 'off') <> 'on'
    THEN
        NEW.updated_at := EXTRACT(EPOCH FROM clock_timestamp())::BIGINT;
    END IF;
    RETURN NEW;
END;
$$;

SET LOCAL chaos.preserve_updated_at = 'on';

WITH candidate_messages AS (
    SELECT
        p.id,
        je.seq,
        0::BIGINT AS position,
        je.payload_json #>> '{payload,message}' AS message
    FROM processes AS p
    JOIN journal_entries AS je ON je.process_id = p.id
    WHERE (btrim(p.first_user_message) = '' OR btrim(p.title) = '')
      AND je.item_type = 'event_msg'
      AND je.payload_json ->> 'type' = 'event_msg'
      AND je.payload_json #>> '{payload,type}' = 'user_message'
      AND btrim(je.payload_json #>> '{payload,message}') <> ''

    UNION ALL

    SELECT
        p.id,
        je.seq,
        content.position,
        content.value ->> 'text' AS message
    FROM processes AS p
    JOIN journal_entries AS je ON je.process_id = p.id
    CROSS JOIN LATERAL jsonb_array_elements(
        CASE
            WHEN jsonb_typeof(je.payload_json #> '{payload,content}') = 'array'
            THEN je.payload_json #> '{payload,content}'
            ELSE '[]'::jsonb
        END
    ) WITH ORDINALITY AS content(value, position)
    WHERE (btrim(p.first_user_message) = '' OR btrim(p.title) = '')
      AND je.item_type = 'response_item'
      AND je.payload_json ->> 'type' = 'response_item'
      AND je.payload_json #>> '{payload,type}' = 'message'
      AND je.payload_json #>> '{payload,role}' = 'user'
      AND content.value ->> 'type' = 'input_text'
      AND btrim(content.value ->> 'text') <> ''
),
cleaned_candidates AS (
    SELECT
        id,
        seq,
        position,
        btrim(
            regexp_replace(
                regexp_replace(
                    message,
                    '^\s*(<environment_context>.*</environment_context>\s*)+',
                    '',
                    's'
                ),
                '^\s*## My request for [^:]+:\s*',
                ''
            )
        ) AS message
    FROM candidate_messages
),
first_messages AS (
    SELECT DISTINCT ON (id) id, message
    FROM cleaned_candidates
    WHERE message <> ''
    ORDER BY id, seq ASC, position ASC
)
UPDATE processes AS p
SET
    first_user_message = CASE
        WHEN btrim(p.first_user_message) = '' THEN first_messages.message
        ELSE p.first_user_message
    END,
    title = CASE
        WHEN btrim(p.title) = '' THEN first_messages.message
        ELSE p.title
    END
FROM first_messages
WHERE p.id = first_messages.id;

-- ==== 0014_attested_review_scope.sql
ALTER TABLE review_runs
    ADD COLUMN attestation_subject TEXT;

UPDATE review_runs
SET attestation_subject = review_run_subject
WHERE attestation_subject IS NULL;

ALTER TABLE review_runs
    ALTER COLUMN attestation_subject SET NOT NULL;

DROP TRIGGER review_runs_identity_immutable ON review_runs;

CREATE TRIGGER review_runs_identity_immutable
BEFORE UPDATE OF id, review_run_subject, attestation_subject, owner_process_id ON review_runs
FOR EACH ROW
EXECUTE FUNCTION chaos_review_run_identity_immutable();

-- ==== 0015_cron_execution_policy.sql
-- Existing shell jobs deliberately have no durable authorization.
ALTER TABLE cron_jobs ADD COLUMN execution_policy TEXT;

-- PostgreSQL expands SELECT * when the view is created.
CREATE OR REPLACE VIEW due_cron_jobs AS
SELECT * FROM cron_jobs
WHERE enabled = TRUE
  AND next_run_at IS NOT NULL
  AND next_run_at <= EXTRACT(EPOCH FROM NOW())::BIGINT
ORDER BY next_run_at ASC;

-- ==== 0016_turn_model_provider.sql
-- One-time journal format upgrade. Stop old writers before upgrading.
-- Acquire the DDL lock before touching rows; fail promptly if writers are busy.
-- SQLx runs this migration in a transaction, including the append-only guard.
SET LOCAL lock_timeout = '5s';
DROP TRIGGER journal_entries_no_update ON journal_entries;

UPDATE journal_entries AS turn
SET payload_json = jsonb_set(
    turn.payload_json,
    '{payload,model_provider}',
    to_jsonb(COALESCE(
        (
            SELECT meta.payload_json #>> '{payload,model_provider}'
            FROM journal_entries AS meta
            WHERE meta.process_id = turn.process_id
              AND meta.seq <= turn.seq
              AND meta.item_type = 'session_meta'
              AND jsonb_typeof(meta.payload_json #> '{payload,model_provider}') = 'string'
              AND btrim(meta.payload_json #>> '{payload,model_provider}') <> ''
            ORDER BY meta.seq DESC
            LIMIT 1
        ),
        p.model_provider
    ))
)
FROM processes AS p
WHERE p.id = turn.process_id
  AND turn.item_type = 'turn_context'
  AND (
      turn.payload_json #> '{payload,model_provider}' IS NULL
      OR turn.payload_json #> '{payload,model_provider}' = 'null'::jsonb
  );

CREATE TRIGGER journal_entries_no_update
BEFORE UPDATE ON journal_entries
FOR EACH ROW
EXECUTE FUNCTION chaos_raise_append_only();

-- ==== 0017_legacy_turn_provider_writes.sql
-- Repair turns appended by old writers after 0016, then normalize future
-- legacy inserts in the same transaction. Never use a runtime/global default.
SET LOCAL lock_timeout = '5s';
DROP TRIGGER journal_entries_no_update ON journal_entries;

-- Share the recovery policy between the backfill and future legacy inserts.
CREATE OR REPLACE FUNCTION chaos_legacy_turn_provider(target_process_id text, target_seq bigint)
RETURNS text LANGUAGE sql VOLATILE AS $$
    SELECT COALESCE(
        (
            SELECT meta.payload_json #>> '{payload,model_provider}'
            FROM journal_entries AS meta
            WHERE meta.process_id = target_process_id
              AND meta.seq <= target_seq
              AND meta.item_type = 'session_meta'
              AND jsonb_typeof(meta.payload_json #> '{payload,model_provider}') = 'string'
              AND btrim(meta.payload_json #>> '{payload,model_provider}') <> ''
            ORDER BY meta.seq DESC
            LIMIT 1
        ),
        (SELECT p.model_provider FROM processes AS p WHERE p.id = target_process_id)
    );
$$;

UPDATE journal_entries AS turn
SET payload_json = jsonb_set(
    turn.payload_json,
    '{payload,model_provider}',
    to_jsonb(chaos_legacy_turn_provider(turn.process_id, turn.seq))
)
WHERE turn.item_type = 'turn_context'
  AND (
      turn.payload_json #> '{payload,model_provider}' IS NULL
      OR turn.payload_json #> '{payload,model_provider}' = 'null'::jsonb
  );

CREATE TRIGGER journal_entries_no_update
BEFORE UPDATE ON journal_entries
FOR EACH ROW
EXECUTE FUNCTION chaos_raise_append_only();

CREATE OR REPLACE FUNCTION chaos_fill_legacy_turn_provider() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    provider text;
BEGIN
    provider := chaos_legacy_turn_provider(NEW.process_id, NEW.seq);

    IF provider IS NULL OR
       jsonb_typeof(NEW.payload_json -> 'payload') IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'cannot recover legacy turn model_provider; upgrade the journal writer';
    END IF;
    NEW.payload_json := jsonb_set(
        NEW.payload_json, '{payload,model_provider}', to_jsonb(provider)
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS journal_entries_legacy_turn_provider ON journal_entries;
CREATE TRIGGER journal_entries_legacy_turn_provider
BEFORE INSERT ON journal_entries
FOR EACH ROW
WHEN (
    NEW.item_type = 'turn_context'
    AND (
        NEW.payload_json #> '{payload,model_provider}' IS NULL
        OR NEW.payload_json #> '{payload,model_provider}' = 'null'::jsonb
    )
)
EXECUTE FUNCTION chaos_fill_legacy_turn_provider();

-- ==== 0018_user_settings.sql
CREATE TABLE user_settings (
    id BIGINT PRIMARY KEY CHECK (id = 1),
    schema_version BIGINT NOT NULL CHECK (schema_version = 1),
    revision BIGINT NOT NULL,
    settings_json TEXT NOT NULL,
    migration_digest TEXT
);
INSERT INTO user_settings VALUES (1, 1, 0, '{}', NULL);

CREATE TABLE remembered_approvals (
    id TEXT PRIMARY KEY,
    installation_id TEXT NOT NULL,
    scope TEXT NOT NULL,
    kind TEXT NOT NULL,
    subject TEXT NOT NULL,
    identity TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('active', 'revoked', 'pending_reapproval')),
    payload_json TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    UNIQUE (installation_id, scope, kind, subject, identity)
);
CREATE INDEX remembered_approvals_lookup
    ON remembered_approvals (installation_id, scope, kind, state);

CREATE TABLE configuration_events (
    id TEXT PRIMARY KEY,
    event TEXT NOT NULL,
    subject TEXT NOT NULL,
    created_at BIGINT NOT NULL
);

CREATE TABLE approval_revision (
    id BIGINT PRIMARY KEY CHECK (id = 1),
    revision BIGINT NOT NULL
);
INSERT INTO approval_revision VALUES (1, 0);

CREATE TABLE user_policy_sources (
    id BIGINT PRIMARY KEY CHECK (id = 1),
    sources_json TEXT NOT NULL
);
INSERT INTO user_policy_sources VALUES (1, '[]');

-- ==== 0019_hooks.sql
CREATE TABLE hooks (
    id TEXT PRIMARY KEY NOT NULL,
    revision BIGINT NOT NULL,
    definition_json TEXT NOT NULL,
    enabled BIGINT NOT NULL CHECK (enabled IN (0, 1))
);
CREATE TABLE hook_revision (
    id BIGINT PRIMARY KEY CHECK (id = 1),
    revision BIGINT NOT NULL
);
INSERT INTO hook_revision VALUES (1, 0);

-- ==== 0020_planning.sql
CREATE TABLE planning_workspace_sequence (
    id BIGINT PRIMARY KEY CHECK (id = 1),
    next_workspace BIGINT NOT NULL
);
INSERT INTO planning_workspace_sequence VALUES (1, 0);
CREATE TABLE planning_workspaces (
    id TEXT PRIMARY KEY,
    code TEXT NOT NULL UNIQUE CHECK (code ~ '^[0-9A-F]{6}$'),
    name TEXT NOT NULL,
    revision SMALLINT NOT NULL DEFAULT 1,
    next_plan BIGINT NOT NULL DEFAULT 0
);
CREATE TABLE planning_projects (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL REFERENCES planning_workspaces(id),
    name TEXT NOT NULL,
    revision SMALLINT NOT NULL DEFAULT 1,
    UNIQUE (workspace_id, name),
    UNIQUE (workspace_id, id)
);
CREATE TABLE planning_checkouts (
    installation_id TEXT NOT NULL,
    path TEXT NOT NULL,
    project_id TEXT NOT NULL REFERENCES planning_projects(id),
    PRIMARY KEY (installation_id, path)
);
CREATE TABLE planning_plans (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL REFERENCES planning_workspaces(id),
    code TEXT NOT NULL CHECK (code ~ '^[0-9A-F]{4}$'),
    title TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','completed','cancelled')),
    revision SMALLINT NOT NULL DEFAULT 1,
    next_task BIGINT NOT NULL DEFAULT 1,
    next_event BIGINT NOT NULL DEFAULT 1,
    UNIQUE (workspace_id, code),
    UNIQUE (workspace_id, id)
);
CREATE TABLE planning_tasks (
    id TEXT PRIMARY KEY,
    plan_id TEXT NOT NULL REFERENCES planning_plans(id),
    number BIGINT NOT NULL CHECK (number > 0),
    title TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','in_progress','blocked','completed','cancelled')),
    revision SMALLINT NOT NULL DEFAULT 1,
    parent_id TEXT,
    position BIGINT NOT NULL DEFAULT 0,
    UNIQUE (plan_id, id),
    UNIQUE (plan_id, number),
    FOREIGN KEY (plan_id, parent_id) REFERENCES planning_tasks(plan_id, id),
    CHECK (parent_id IS NULL OR parent_id <> id)
);
CREATE INDEX planning_tasks_order ON planning_tasks(plan_id, parent_id, position, number);
CREATE TABLE planning_targets (
    workspace_id TEXT NOT NULL,
    plan_id TEXT NOT NULL,
    task_id TEXT NOT NULL,
    project_id TEXT NOT NULL,
    PRIMARY KEY (task_id, project_id),
    FOREIGN KEY (workspace_id, plan_id) REFERENCES planning_plans(workspace_id, id),
    FOREIGN KEY (plan_id, task_id) REFERENCES planning_tasks(plan_id, id),
    FOREIGN KEY (workspace_id, project_id) REFERENCES planning_projects(workspace_id, id)
);
CREATE TABLE planning_history (
    id TEXT PRIMARY KEY,
    plan_id TEXT NOT NULL REFERENCES planning_plans(id),
    seq BIGINT NOT NULL,
    task_id TEXT REFERENCES planning_tasks(id),
    actor TEXT NOT NULL,
    installation_id TEXT NOT NULL,
    event JSONB NOT NULL,
    created_at TEXT NOT NULL DEFAULT clock_timestamp()::text,
    UNIQUE (plan_id, seq)
);
CREATE INDEX planning_history_page ON planning_history(plan_id, seq);
CREATE TABLE planning_requests (
    actor TEXT NOT NULL,
    request_id TEXT NOT NULL,
    payload JSONB NOT NULL,
    result JSONB,
    PRIMARY KEY (actor, request_id)
);
CREATE TABLE planning_attachments (
    session_id TEXT PRIMARY KEY,
    plan_id TEXT NOT NULL REFERENCES planning_plans(id)
);
CREATE TABLE planning_edges (
    plan_id TEXT NOT NULL REFERENCES planning_plans(id),
    parent_id TEXT NOT NULL,
    child_id TEXT NOT NULL,
    PRIMARY KEY (plan_id, parent_id, child_id),
    FOREIGN KEY (plan_id, parent_id) REFERENCES planning_tasks(plan_id, id),
    FOREIGN KEY (plan_id, child_id) REFERENCES planning_tasks(plan_id, id),
    CHECK (parent_id <> child_id)
);
CREATE TABLE planning_paths (
    plan_id TEXT NOT NULL REFERENCES planning_plans(id),
    ancestor_id TEXT NOT NULL REFERENCES planning_tasks(id),
    descendant_id TEXT NOT NULL REFERENCES planning_tasks(id),
    min_depth BIGINT NOT NULL,
    path_count NUMERIC NOT NULL,
    PRIMARY KEY (plan_id, ancestor_id, descendant_id)
);
CREATE INDEX planning_paths_reverse ON planning_paths(plan_id, descendant_id, ancestor_id);

-- Shared lock order: plan row, then graph advisory lock. Never a session lock.
CREATE FUNCTION planning_lock(p TEXT) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'planning graph writes require READ COMMITTED';
    END IF;
    PERFORM 1 FROM planning_plans WHERE id = p FOR UPDATE;
    PERFORM pg_advisory_xact_lock(hashtextextended('chaos:planning:' || p, 0));
END $$;

CREATE FUNCTION planning_task_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM planning_lock(NEW.plan_id);
    IF TG_OP = 'UPDATE' AND (NEW.id <> OLD.id OR NEW.plan_id <> OLD.plan_id OR NEW.number <> OLD.number) THEN
        RAISE EXCEPTION 'task identity is immutable';
    END IF;
    IF NEW.parent_id IS NOT NULL AND EXISTS (
        WITH RECURSIVE ancestors(id) AS (
            SELECT NEW.parent_id UNION
            SELECT t.parent_id FROM planning_tasks t JOIN ancestors a ON t.id = a.id
            WHERE t.parent_id IS NOT NULL
        ) SELECT 1 FROM ancestors WHERE id = NEW.id
    ) THEN
        RAISE EXCEPTION 'containment cycle';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER planning_task_guard BEFORE INSERT OR UPDATE ON planning_tasks
FOR EACH ROW EXECUTE FUNCTION planning_task_guard();

CREATE FUNCTION planning_task_self() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO planning_paths VALUES (NEW.plan_id, NEW.id, NEW.id, 0, 1);
    RETURN NEW;
END $$;
CREATE TRIGGER planning_task_self AFTER INSERT ON planning_tasks
FOR EACH ROW EXECUTE FUNCTION planning_task_self();

-- Rebuild and validation use edges, never potentially damaged closure rows.
CREATE FUNCTION planning_path_truth(p TEXT)
RETURNS TABLE (ancestor_id TEXT, descendant_id TEXT, min_depth BIGINT, path_count NUMERIC)
LANGUAGE sql AS $$
    WITH RECURSIVE walk(a, d, depth) AS (
        SELECT id, id, 0::bigint FROM planning_tasks WHERE plan_id = p
        UNION ALL
        SELECT w.a, e.child_id, w.depth + 1 FROM walk w
        JOIN planning_edges e ON e.parent_id = w.d AND e.plan_id = p
    )
    SELECT a, d, min(depth), count(*)::numeric FROM walk GROUP BY a, d
$$;
CREATE FUNCTION planning_rebuild_paths(p TEXT) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM planning_lock(p);
    DELETE FROM planning_paths WHERE plan_id = p;
    INSERT INTO planning_paths SELECT p, * FROM planning_path_truth(p);
END $$;
CREATE FUNCTION planning_validate_paths(p TEXT)
RETURNS TABLE (ancestor_id TEXT, descendant_id TEXT) LANGUAGE sql AS $$
    SELECT coalesce(s.ancestor_id,t.ancestor_id), coalesce(s.descendant_id,t.descendant_id)
    FROM (SELECT * FROM planning_paths WHERE plan_id = p) s
    FULL JOIN planning_path_truth(p) t USING (ancestor_id, descendant_id)
    WHERE s.min_depth IS DISTINCT FROM t.min_depth OR s.path_count IS DISTINCT FROM t.path_count
$$;

CREATE FUNCTION planning_edge_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'replace edges with delete and insert';
    END IF;
    IF TG_OP = 'DELETE' THEN
        PERFORM planning_lock(OLD.plan_id);
        RETURN OLD;
    END IF;
    PERFORM planning_lock(NEW.plan_id);
    IF NEW.parent_id = NEW.child_id OR EXISTS (
        WITH RECURSIVE reachable(id) AS (
            SELECT NEW.child_id UNION
            SELECT e.child_id FROM planning_edges e JOIN reachable r ON e.parent_id = r.id
            WHERE e.plan_id = NEW.plan_id
        ) SELECT 1 FROM reachable WHERE id = NEW.parent_id
    ) THEN
        RAISE EXCEPTION 'dependency cycle';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER planning_edge_guard BEFORE INSERT OR UPDATE OR DELETE ON planning_edges
FOR EACH ROW EXECUTE FUNCTION planning_edge_guard();
CREATE FUNCTION planning_edge_apply() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        -- Repair exact multiplicities and minimum depths after removing alternate paths.
        PERFORM planning_rebuild_paths(OLD.plan_id);
        RETURN OLD;
    END IF;
    INSERT INTO planning_paths
    SELECT NEW.plan_id, a.ancestor_id, d.descendant_id,
           a.min_depth + d.min_depth + 1, a.path_count * d.path_count
    FROM planning_paths a CROSS JOIN planning_paths d
    WHERE a.plan_id = NEW.plan_id AND d.plan_id = NEW.plan_id
      AND a.descendant_id = NEW.parent_id AND d.ancestor_id = NEW.child_id
    ON CONFLICT (plan_id, ancestor_id, descendant_id) DO UPDATE
    SET path_count = planning_paths.path_count + excluded.path_count,
        min_depth = least(planning_paths.min_depth, excluded.min_depth);
    RETURN NEW;
END $$;
CREATE TRIGGER planning_edge_apply AFTER INSERT OR DELETE ON planning_edges
FOR EACH ROW EXECUTE FUNCTION planning_edge_apply();

-- ==== 0021_planning_content.sql
ALTER TABLE planning_plans ADD COLUMN body TEXT NOT NULL DEFAULT '';
ALTER TABLE planning_plans ADD COLUMN body_revision SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE planning_plans ADD COLUMN incorporated_seq BIGINT NOT NULL DEFAULT 0;
ALTER TABLE planning_tasks ADD COLUMN body TEXT NOT NULL DEFAULT '';
ALTER TABLE planning_tasks ADD COLUMN body_revision SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE planning_tasks ADD COLUMN incorporated_seq BIGINT NOT NULL DEFAULT 0;

CREATE TABLE planning_clarifications (
    plan_id TEXT NOT NULL REFERENCES planning_plans(id),
    task_id TEXT,
    seq BIGINT NOT NULL,
    text TEXT NOT NULL,
    actor TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP::TEXT,
    PRIMARY KEY (plan_id, seq),
    FOREIGN KEY (plan_id, task_id) REFERENCES planning_tasks(plan_id, id)
);
CREATE INDEX planning_clarifications_item ON planning_clarifications(plan_id, task_id, seq);

-- ==== 0022_planning_consolidations.sql
CREATE TABLE planning_consolidations (
    id TEXT PRIMARY KEY,
    plan_id TEXT NOT NULL REFERENCES planning_plans(id),
    task_id TEXT,
    actor TEXT NOT NULL,
    installation_id TEXT NOT NULL,
    origin_call_id TEXT NOT NULL,
    request_id TEXT NOT NULL,
    request JSONB NOT NULL,
    input JSONB NOT NULL,
    state TEXT NOT NULL DEFAULT 'queued'
        CHECK (state IN ('queued','running','completed','failed','cancelled','stale')),
    execution_id TEXT,
    result_body TEXT,
    error TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP::TEXT,
    UNIQUE (actor, request_id),
    FOREIGN KEY (plan_id, task_id) REFERENCES planning_tasks(plan_id, id)
);
CREATE INDEX planning_consolidations_owner ON planning_consolidations(actor, state, id);

-- ==== 0023_drop_memory_tables.sql
-- The memory-consolidation and backfill subsystems were removed; nothing
-- reads or writes these tables anymore.
DROP INDEX IF EXISTS idx_stage1_outputs_source_updated_at;
DROP TABLE IF EXISTS stage1_outputs;
DROP INDEX IF EXISTS idx_jobs_kind_status_retry_lease;
DROP TABLE IF EXISTS jobs;
DROP TABLE IF EXISTS backfill_state;

-- ==== 0024_agent_roles.sql
CREATE TABLE agent_roles (
    name TEXT PRIMARY KEY NOT NULL,
    format TEXT NOT NULL CHECK (format IN ('toml', 'md')),
    source TEXT NOT NULL,
    base_dir TEXT,
    revision BIGINT NOT NULL,
    enabled BIGINT NOT NULL CHECK (enabled IN (0, 1)),
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
);

-- ==== 0025_user_documents.sql
-- Named user documents that used to be files: custom modes, prompts,
-- syntax themes, and halluacinate scripts.
CREATE TABLE user_documents (
    kind TEXT NOT NULL CHECK (kind IN ('mode', 'prompt', 'theme', 'script')),
    name TEXT NOT NULL,
    source TEXT NOT NULL,
    revision BIGINT NOT NULL,
    enabled BIGINT NOT NULL CHECK (enabled IN (0, 1)),
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    PRIMARY KEY (kind, name)
);

-- ==== 0026_execution_ledger.sql
-- Same control-plane contract as SQLite; process journals remain append-only.
CREATE TABLE execution_sessions (
    session_id TEXT PRIMARY KEY,
    scope TEXT NOT NULL,
    process_id TEXT,
    state TEXT NOT NULL CHECK (state IN ('idle', 'active', 'unknown', 'closed')),
    active_turn_id TEXT,
    owner_id TEXT NOT NULL,
    lease_token TEXT NOT NULL,
    expires_at_ms BIGINT NOT NULL,
    CHECK ((state IN ('idle', 'closed') AND active_turn_id IS NULL)
        OR (state = 'active' AND active_turn_id IS NOT NULL)
        OR state = 'unknown')
);
CREATE INDEX execution_sessions_scope ON execution_sessions (scope, session_id);
CREATE UNIQUE INDEX execution_sessions_live_process ON execution_sessions (process_id)
    WHERE state != 'closed' AND process_id IS NOT NULL;

CREATE TABLE execution_turns (
    session_id TEXT NOT NULL REFERENCES execution_sessions(session_id),
    turn_id TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN
        ('accepted', 'running', 'completed', 'failed', 'interrupted', 'timed_out', 'unknown')),
    outcome_json TEXT,
    PRIMARY KEY (session_id, turn_id)
);

-- ==== 0027_execution_resolutions.sql
-- Same audit/idempotency contract as SQLite.
ALTER TABLE execution_sessions ADD COLUMN recovery_epoch BIGINT NOT NULL DEFAULT 0
    CHECK (recovery_epoch >= 0);
CREATE TABLE execution_resolutions (
    session_id TEXT PRIMARY KEY REFERENCES execution_sessions(session_id),
    resolution_id TEXT NOT NULL UNIQUE,
    request_json TEXT NOT NULL,
    resolved_at_ms BIGINT NOT NULL
);

-- ==== 0028_execution_scope_bindings.sql
CREATE TABLE execution_scopes (
    scope TEXT PRIMARY KEY,
    policy_digest TEXT
);
CREATE TABLE execution_process_bindings (
    process_id TEXT PRIMARY KEY,
    scope TEXT,
    policy_digest TEXT
);
INSERT INTO execution_process_bindings (process_id, scope, policy_digest)
SELECT process_id, CASE WHEN COUNT(DISTINCT scope) = 1 THEN MIN(scope) ELSE NULL END, NULL
FROM execution_sessions WHERE process_id IS NOT NULL GROUP BY process_id;

-- ==== 0029_execution_outbox.sql
CREATE TABLE execution_delivery_targets (
    scope TEXT PRIMARY KEY REFERENCES execution_scopes(scope),
    destination_digest TEXT NOT NULL
);
CREATE TABLE execution_outbox (
    event_id TEXT PRIMARY KEY,
    event_key TEXT NOT NULL UNIQUE,
    scope TEXT NOT NULL,
    session_id TEXT NOT NULL REFERENCES execution_sessions(session_id),
    turn_id TEXT,
    kind TEXT NOT NULL,
    created_at_ms BIGINT NOT NULL,
    body_json TEXT NOT NULL,
    attempts BIGINT NOT NULL DEFAULT 0,
    next_attempt_at_ms BIGINT NOT NULL,
    owner_id TEXT NOT NULL DEFAULT '',
    lease_token TEXT,
    expires_at_ms BIGINT NOT NULL DEFAULT 0,
    delivered_at_ms BIGINT
);
CREATE INDEX execution_outbox_due ON execution_outbox(scope, delivered_at_ms, next_attempt_at_ms);

-- ==== 0030_execution_invocations.sql
ALTER TABLE execution_turns ADD COLUMN accounting_enabled INTEGER NOT NULL DEFAULT 0;
CREATE TABLE execution_invocations (
    invocation_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    turn_id TEXT NOT NULL,
    request_json TEXT NOT NULL,
    started_at_ms BIGINT NOT NULL,
    state TEXT NOT NULL,
    receipt_json TEXT,
    duplicate_receipt_of TEXT,
    finished_at_ms BIGINT,
    FOREIGN KEY (session_id, turn_id) REFERENCES execution_turns(session_id, turn_id)
);
CREATE INDEX execution_invocations_turn ON execution_invocations(session_id, turn_id);
CREATE TABLE execution_provider_receipts (
    receipt_key TEXT PRIMARY KEY,
    invocation_id TEXT NOT NULL UNIQUE REFERENCES execution_invocations(invocation_id)
);

-- ==== 0031_execution_replay.sql
-- Observation-only replay. These rows never authorize execution or recovery.
CREATE TABLE execution_replay (
    session_id TEXT PRIMARY KEY REFERENCES execution_sessions(session_id),
    sequence BIGINT NOT NULL DEFAULT 0 CHECK (sequence >= 0)
);
CREATE TABLE execution_replay_events (
    session_id TEXT NOT NULL REFERENCES execution_sessions(session_id),
    sequence BIGINT NOT NULL CHECK (sequence > 0),
    event_json TEXT NOT NULL,
    event_bytes BIGINT NOT NULL CHECK (event_bytes > 0),
    PRIMARY KEY (session_id, sequence)
);

-- ==== 0032_execution_retention.sql
-- Explicit point-in-time export and operator attestation. No payload deletion:
-- live deduplication still compares original immutable receipts/outcomes.
CREATE TABLE execution_archives (
    session_id TEXT NOT NULL REFERENCES execution_sessions(session_id),
    scope TEXT NOT NULL,
    manifest_digest TEXT NOT NULL,
    manifest_json TEXT NOT NULL,
    revision BIGINT NOT NULL CHECK (revision > 0),
    exported_at_ms BIGINT NOT NULL,
    sealed_at_ms BIGINT,
    archive_reference TEXT,
    actor TEXT,
    PRIMARY KEY (session_id, manifest_digest),
    UNIQUE (session_id, revision),
    CHECK ((sealed_at_ms IS NULL AND archive_reference IS NULL AND actor IS NULL)
        OR (sealed_at_ms IS NOT NULL AND archive_reference IS NOT NULL AND actor IS NOT NULL))
);

-- ==== 0033_execution_billing.sql
CREATE TABLE execution_price_schedules (
    scope TEXT NOT NULL REFERENCES execution_scopes(scope),
    version TEXT NOT NULL,
    schedule_json TEXT NOT NULL,
    created_at_ms BIGINT NOT NULL,
    PRIMARY KEY (scope, version)
);
CREATE TABLE execution_reconciliations (
    reconciliation_id TEXT PRIMARY KEY,
    scope TEXT NOT NULL REFERENCES execution_scopes(scope),
    session_id TEXT NOT NULL,
    turn_id TEXT NOT NULL,
    invocation_id TEXT NOT NULL REFERENCES execution_invocations(invocation_id),
    receipt_key TEXT NOT NULL UNIQUE,
    record_json TEXT NOT NULL,
    created_at_ms BIGINT NOT NULL,
    FOREIGN KEY (session_id, turn_id) REFERENCES execution_turns(session_id, turn_id)
);
CREATE INDEX execution_reconciliations_turn ON execution_reconciliations(session_id, turn_id);

-- ==== 0034_execution_descendants.sql
CREATE TABLE execution_descendants (
    process_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    root_turn_id TEXT NOT NULL,
    parent_process_id TEXT NOT NULL,
    registered_at_ms BIGINT NOT NULL,
    FOREIGN KEY (session_id, root_turn_id) REFERENCES execution_turns(session_id, turn_id)
);
CREATE INDEX execution_descendants_root ON execution_descendants(session_id, root_turn_id);
ALTER TABLE execution_invocations ADD COLUMN source_turn_id TEXT;
ALTER TABLE execution_turns ADD COLUMN accounting_coverage TEXT NOT NULL DEFAULT 'direct_logical_sampling_and_compaction';

-- ==== 0035_installation_settings.sql
CREATE TABLE installation_settings (
    installation_id TEXT PRIMARY KEY,
    revision BIGINT NOT NULL,
    settings_json TEXT NOT NULL
);

-- ==== 0036_lease_fencing.sql
-- Same fencing contract as SQLite: monotonic per-resource tokens with a
-- high-water that survives release. Pre-existing grants are fenced.
DROP VIEW IF EXISTS active_process_leases;

ALTER TABLE process_leases DROP COLUMN lease_token;
ALTER TABLE process_leases ADD COLUMN lease_token BIGINT;
ALTER TABLE process_leases ADD COLUMN last_issued BIGINT NOT NULL DEFAULT 0;

CREATE VIEW active_process_leases AS
    SELECT
        pl.process_id,
        pl.owner_id,
        pl.lease_token,
        pl.expires_at,
        pl.updated_at,
        p.source,
        p.title,
        p.cwd,
        p.model_provider
    FROM process_leases AS pl
    JOIN processes AS p ON p.id = pl.process_id
    WHERE p.archived_at IS NULL
      AND pl.lease_token IS NOT NULL
      AND pl.expires_at > EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT
    ORDER BY pl.expires_at ASC, pl.process_id ASC;

ALTER TABLE execution_sessions DROP COLUMN lease_token;
ALTER TABLE execution_sessions ADD COLUMN lease_token BIGINT;
ALTER TABLE execution_sessions ADD COLUMN last_issued BIGINT NOT NULL DEFAULT 0;

ALTER TABLE execution_outbox DROP COLUMN lease_token;
ALTER TABLE execution_outbox ADD COLUMN lease_token BIGINT;
ALTER TABLE execution_outbox ADD COLUMN last_issued BIGINT NOT NULL DEFAULT 0;

-- ==== 0037_spool_submit_saga.sql
-- saga_json holds the submit saga's progress (direction, step, attempt) plus
-- the poll wiring it needs to finish; NULL once the saga completes or aborts.
ALTER TABLE spool_jobs ADD COLUMN saga_json TEXT;

-- ==== 0038_recovery_checkpoints.sql
-- Counters outlive retained notes, including an empty checkpoint history.
CREATE TABLE recovery_checkpoint_counters (
    process_id TEXT PRIMARY KEY NOT NULL REFERENCES processes(id) ON DELETE CASCADE,
    last_checkpoint_id BIGINT NOT NULL DEFAULT 0 CHECK (last_checkpoint_id >= 0),
    last_recovery_id BIGINT NOT NULL DEFAULT 0 CHECK (last_recovery_id >= 0)
);

CREATE TABLE recovery_checkpoints (
    process_id TEXT NOT NULL REFERENCES processes(id) ON DELETE CASCADE,
    id BIGINT NOT NULL CHECK (id > 0),
    recovery_id BIGINT NOT NULL CHECK (recovery_id > 0),
    call_id TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    note_json TEXT NOT NULL CHECK (octet_length(note_json) <= 16384),
    observation_json TEXT NOT NULL CHECK (octet_length(observation_json) <= 16384),
    PRIMARY KEY (process_id, id),
    UNIQUE (process_id, call_id)
);
