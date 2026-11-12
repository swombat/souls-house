-- Merge a resident's subscription Chaos store (the old `.chaos/oauth-runtime`
-- home) into their main Chaos store. Run in the DESTINATION database, as a
-- superuser, inside one transaction:
--
--   psql -d <main db> -v ON_ERROR_STOP=1 --single-transaction -v src=<oauth db> -f oauth_store_merge.sql
--
-- The resident's container must be stopped: that is what keeps every writer of
-- both stores still. Nothing here overwrites a destination row. Any check that
-- fails raises, and the whole transaction, marker included, rolls back. The
-- source database is only read and is kept.
--
-- Tables are classified explicitly (MANIFEST below). A non-empty source table
-- that is not classified refuses the merge: a new Chaos table has to be read and
-- placed by a person before it can be carried or left behind.

SELECT set_config('house_merge.src', :'src', true);
SELECT pg_advisory_xact_lock(hashtext('house_oauth_store_merge'));
SELECT set_config('house_merge.created_dblink',
                  CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'dblink')
                       THEN 'no' ELSE 'yes' END, true);
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE TABLE IF NOT EXISTS house_oauth_store_merges (
    source_db TEXT NOT NULL,
    source_oid OID NOT NULL,
    dest_db TEXT NOT NULL,
    dest_oid OID NOT NULL,
    migrations TEXT NOT NULL,
    processes BIGINT NOT NULL,
    journal_entries BIGINT NOT NULL,
    digest TEXT NOT NULL,
    merged_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (source_db, source_oid, dest_db, dest_oid)
);

DO $merge$
DECLARE
    src TEXT := current_setting('house_merge.src');
    conn TEXT;
    src_oid OID;
    dst_oid OID;
    -- Carried with their ids; a collision with the destination refuses.
    -- Order matters only for foreign keys: processes first.
    copy_tables TEXT[] := ARRAY['processes', 'journal_entries', 'process_leases',
                                'process_dynamic_tools', 'recovery_checkpoint_counters',
                                'recovery_checkpoints'];
    -- Rebuilt by the AFTER INSERT trigger on processes; compared, not copied.
    derived_tables TEXT[] := ARRAY['process_closure'];
    -- Carried with fresh generated ids (composer history).
    renumber_tables TEXT[] := ARRAY['message_history'];
    -- A cache keyed by (provider, base_url, label): the newer reading wins.
    newer_wins_tables TEXT[] := ARRAY['ration_usage'];
    -- The destination home's own state is authoritative: settings, hooks,
    -- trust, approvals, catalogue cache, singletons. Source rows stay behind
    -- in the retained source database.
    main_wins_tables TEXT[] := ARRAY['settings', 'user_settings', 'user_policy_sources',
                                     'approval_revision', 'remembered_approvals', 'hooks',
                                     'hook_revision', 'project_trust', 'installation_settings',
                                     'configuration_events', 'model_catalog_cache',
                                     'global_mcp_servers', 'user_documents', 'agent_roles',
                                     'planning_workspace_sequence'];
    -- Diagnostics only; nothing reads them back to decide behaviour.
    left_behind_tables TEXT[] := ARRAY['logs', 'ration_history', 'clamp_exchanges'];
    -- Bookkeeping, not resident state.
    meta_tables TEXT[] := ARRAY['_sqlx_migrations', '_recall_migrations',
                                'house_oauth_store_merges'];
    -- Graphs and queues this merge does not know how to join. Must be empty.
    refuse_tables TEXT[] := ARRAY['planning_workspaces', 'planning_projects', 'planning_plans',
                                  'planning_tasks', 'planning_edges', 'planning_paths',
                                  'planning_targets', 'planning_history', 'planning_requests',
                                  'planning_clarifications', 'planning_consolidations',
                                  'planning_checkouts', 'planning_attachments',
                                  'execution_sessions', 'execution_turns', 'execution_scopes',
                                  'execution_resolutions', 'execution_outbox',
                                  'execution_invocations', 'execution_replay',
                                  'execution_replay_events', 'execution_reconciliations',
                                  'execution_provider_receipts', 'execution_process_bindings',
                                  'execution_price_schedules', 'execution_delivery_targets',
                                  'execution_descendants', 'execution_archives',
                                  'agent_jobs', 'agent_job_items', 'review_runs',
                                  'reviewer_attempts', 'cron_jobs', 'spool_jobs'];
    rec RECORD;
    n BIGINT;
    carried BIGINT := 0;
    src_migrations TEXT;
    dst_migrations TEXT;
    cols TEXT;
    coldefs TEXT;
    src_digest TEXT;
    dst_digest TEXT;
    digests TEXT := '';
    processes_n BIGINT := 0;
    journal_n BIGINT := 0;
BEGIN
    IF src !~ '^[a-z0-9_]+$' THEN
        RAISE EXCEPTION 'source database name % is not a plain identifier', src;
    END IF;
    IF src = current_database() THEN
        RAISE EXCEPTION 'source and destination are the same database';
    END IF;
    SELECT oid INTO src_oid FROM pg_database WHERE datname = src;
    IF src_oid IS NULL THEN
        RAISE EXCEPTION 'source database % does not exist on this server', src;
    END IF;
    SELECT oid INTO dst_oid FROM pg_database WHERE datname = current_database();
    -- Local socket, the caller's own role (libpq would otherwise default to the
    -- server's OS user): no credential is ever written here.
    conn := format('dbname=%s user=%s', src, current_user);

    IF EXISTS (SELECT 1 FROM house_oauth_store_merges
               WHERE source_db = src AND source_oid = src_oid
                 AND dest_db = current_database() AND dest_oid = dst_oid) THEN
        RAISE NOTICE 'house_oauth_store_merge: already merged % into %', src, current_database();
        RETURN;
    END IF;

    -- 1. Classify every non-empty source table.
    FOR rec IN
        SELECT * FROM dblink(conn, $q$
            SELECT table_name::text,
                   (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I', table_name),
                                                        false, true, '')))[1]::text::bigint
            FROM information_schema.tables
            WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
        $q$) AS t(table_name TEXT, n BIGINT)
    LOOP
        IF rec.table_name = ANY (refuse_tables) AND rec.n > 0 THEN
            RAISE EXCEPTION 'source table % has % rows; this merge does not carry it', rec.table_name, rec.n;
        ELSIF NOT (rec.table_name = ANY (copy_tables || derived_tables || renumber_tables
                                         || newer_wins_tables || main_wins_tables
                                         || left_behind_tables || meta_tables || refuse_tables))
              AND rec.n > 0 THEN
            RAISE EXCEPTION 'source table % (% rows) is not classified; read it before merging', rec.table_name, rec.n;
        END IF;
        IF rec.table_name = ANY (copy_tables || renumber_tables || newer_wins_tables) THEN
            carried := carried + rec.n;
        END IF;
    END LOOP;

    -- 2. A store with rows to carry must be on exactly the destination's schema.
    SELECT string_agg(version::text || ':' || encode(checksum, 'hex'), ',' ORDER BY version)
      INTO dst_migrations FROM _sqlx_migrations WHERE success;
    SELECT m INTO src_migrations FROM dblink(conn, $q$
        SELECT string_agg(version::text || ':' || encode(checksum, 'hex'), ',' ORDER BY version)
        FROM _sqlx_migrations WHERE success
    $q$) AS t(m TEXT);
    IF carried > 0 AND src_migrations IS DISTINCT FROM dst_migrations THEN
        RAISE EXCEPTION 'source and destination Chaos migrations differ; open the source once with the destination''s binary first';
    END IF;

    IF carried > 0 THEN
        -- 3. Collisions refuse before anything is written. The primary keys
        --    remain the final guard.
        CREATE TEMP TABLE house_merge_src_ids ON COMMIT DROP AS
            SELECT id FROM dblink(conn, 'SELECT id FROM processes') AS t(id TEXT);
        SELECT count(*) INTO n FROM house_merge_src_ids s JOIN processes p ON p.id = s.id;
        IF n > 0 THEN
            RAISE EXCEPTION '% source process ids already exist in the destination; nothing merged', n;
        END IF;

        -- 4. Carry rows with their ids, comparing a whole-row digest per table.
        FOREACH rec.table_name IN ARRAY copy_tables LOOP
            CONTINUE WHEN to_regclass(format('public.%I', rec.table_name)) IS NULL;
            SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum),
                   string_agg(quote_ident(attname) || ' ' || format_type(atttypid, atttypmod), ', ' ORDER BY attnum)
              INTO cols, coldefs
              FROM pg_attribute
             WHERE attrelid = format('public.%I', rec.table_name)::regclass AND attnum > 0 AND NOT attisdropped;
            EXECUTE format('INSERT INTO %I (%s) SELECT %s FROM dblink(%L, %L) AS t(%s)',
                           rec.table_name, cols, cols, conn,
                           format('SELECT %s FROM %I', cols, rec.table_name), coldefs);
            GET DIAGNOSTICS n = ROW_COUNT;
            IF rec.table_name = 'processes' THEN processes_n := n; END IF;
            IF rec.table_name = 'journal_entries' THEN journal_n := n; END IF;
            SELECT d INTO src_digest FROM dblink(conn, format(
                'SELECT md5(coalesce(string_agg(md5(t::text), %L ORDER BY md5(t::text)), %L)) FROM %I t',
                '', '', rec.table_name)) AS x(d TEXT);
            EXECUTE format(
                'SELECT md5(coalesce(string_agg(md5(t::text), %L ORDER BY md5(t::text)), %L)) FROM %I t WHERE %s IN (SELECT id FROM house_merge_src_ids)',
                '', '', rec.table_name,
                CASE rec.table_name WHEN 'processes' THEN 'id' ELSE 'process_id' END)
              INTO dst_digest;
            IF src_digest IS DISTINCT FROM dst_digest THEN
                RAISE EXCEPTION 'table % arrived different from its source (digest mismatch); nothing merged', rec.table_name;
            END IF;
            digests := digests || rec.table_name || '=' || src_digest || ';';
        END LOOP;

        -- 5. The trigger-built lineage must match the source's.
        SELECT d INTO src_digest FROM dblink(conn,
            'SELECT md5(coalesce(string_agg(t::text, '','' ORDER BY t::text), '''')) FROM process_closure t')
            AS x(d TEXT);
        SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t::text), '')) INTO dst_digest
          FROM process_closure t WHERE t.descendant_process_id IN (SELECT id FROM house_merge_src_ids);
        IF src_digest IS DISTINCT FROM dst_digest THEN
            RAISE EXCEPTION 'process_closure rebuilt differently from the source; nothing merged';
        END IF;

        -- 6. Composer history with fresh ids.
        FOREACH rec.table_name IN ARRAY renumber_tables LOOP
            SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum),
                   string_agg(quote_ident(attname) || ' ' || format_type(atttypid, atttypmod), ', ' ORDER BY attnum)
              INTO cols, coldefs
              FROM pg_attribute
             WHERE attrelid = format('public.%I', rec.table_name)::regclass AND attnum > 0
               AND NOT attisdropped AND attidentity = '';
            EXECUTE format('INSERT INTO %I (%s) SELECT %s FROM dblink(%L, %L) AS t(%s)',
                           rec.table_name, cols, cols, conn,
                           format('SELECT %s FROM %I ORDER BY id', cols, rec.table_name), coldefs);
        END LOOP;
    END IF;

    -- 7. Rate-limit cache: insert missing keys, replace only with a newer reading.
    IF carried > 0 THEN
        SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum),
               string_agg(quote_ident(attname) || ' ' || format_type(atttypid, atttypmod), ', ' ORDER BY attnum),
               string_agg(format('%1$I = EXCLUDED.%1$I', attname), ', ' ORDER BY attnum)
                 FILTER (WHERE attname NOT IN ('provider', 'base_url', 'label'))
          INTO cols, coldefs, src_digest
          FROM pg_attribute
         WHERE attrelid = 'public.ration_usage'::regclass AND attnum > 0 AND NOT attisdropped;
        EXECUTE format('INSERT INTO ration_usage (%s) SELECT %s FROM dblink(%L, %L) AS t(%s) '
                       'ON CONFLICT (provider, base_url, label) DO UPDATE SET %s '
                       'WHERE EXCLUDED.observed_at > ration_usage.observed_at',
                       cols, cols, conn, format('SELECT %s FROM ration_usage', cols), coldefs, src_digest);
    END IF;

    -- 8. The marker commits with the rows, bound to this exact pair and schema.
    INSERT INTO house_oauth_store_merges
        (source_db, source_oid, dest_db, dest_oid, migrations, processes, journal_entries, digest)
    VALUES (src, src_oid, current_database(), dst_oid, coalesce(src_migrations, ''),
            processes_n, journal_n, md5(digests));
    RAISE NOTICE 'house_oauth_store_merge: merged % processes, % journal rows from % into %',
        processes_n, journal_n, src, current_database();
END
$merge$;

DO $drop$
BEGIN
    IF current_setting('house_merge.created_dblink') = 'yes' THEN
        DROP EXTENSION dblink;
    END IF;
END
$drop$;
