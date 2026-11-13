# PostgreSQL and pgvector

The PostgreSQL accessory uses the upstream `pgvector/pgvector` image, pinned in
`config/deploy.yml` by digest. The current image contains PostgreSQL 16.16,
Debian 12 (bookworm, glibc 2.36) and pgvector 0.8.7. Do not replace it with a
floating major tag or change the OS/collation provider as part of an extension
update.

The image makes the extension **available server-wide**, but activation is
per database and requires a database administrator:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
SELECT extversion FROM pg_extension WHERE extname = 'vector';
SELECT '[1,2,3]'::vector <-> '[4,6,3]'::vector; -- 5
```

For the main installation this is enabled in the Rails primary database only.
Do not install it in shared templates or all resident databases automatically.
Resident database owners can request activation for their own database; the
image alone does not grant them administrator privileges.

An existing accessory must be replaced/rebooted explicitly to adopt a new image;
a Rails deployment does not replace it. Retain the previous image/container,
preserve the same data mount, environment overrides and private network, and
never run two servers on the same data directory. Hold the deployment lock,
check the database is quiet, and verify backup coverage before the short restart.

After replacement, check the actual server version, extension availability and
the vector query above, as well as Rails, queue and resident connectivity.
Existing resident databases should remain unchanged. Removing the extension
binary is unsafe once a database has vector objects; keep a pgvector-capable
rollback image rather than silently reverting to the plain PostgreSQL image.
