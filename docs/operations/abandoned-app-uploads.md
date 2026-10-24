# Abandoned phone-app uploads (#103)

The hourly `AbandonedAppUploadsJob` removes a bounded batch of uploads explicitly
tagged `metadata.app_upload`, strictly older than 24 hours, with no Active Storage
attachment. This is staging-upload retention, not message retention: sent files,
including files on discarded messages, untagged blobs and resident-owned files or
memory are outside its scope. Expired uploads must be uploaded again before send.

The sweep and `Messages::PostFromHuman` serialize through the blob row lock.
Selection is not permission to delete: eligibility is checked again under the
lock; a send holding it is skipped. A successful claim leaves an attachment that
protects the file. If cleanup wins, the send refuses the now-missing blob through
the existing `invalid_attachment` response instead of an attachment foreign-key
error.

Cleanup commits the blob-row removal before deleting storage bytes. Storage
failure can leave orphan bytes, but cannot resurrect a claimable row pointing to
missing bytes. Each row's failure is logged with its blob ID and exception class,
without filenames, storage keys or service-error details; other candidates in the
batch still run. This narrow change adds no durable storage-deletion ledger.
Inspect the cleanup error logs: an already-deleted blob row will not be selected
again, whereas a row whose deletion rolled back can be retried next hour.
Do not turn that inspection into a general untagged-blob purge.

Rollback disables future cleanup by reverting the job and recurring entry. It
cannot recover purged files. Existing backups are not an application-level undo.

## Review and notice

Daniel authorised the bounded build in planning `wYGGOY/jRzgOj`, with Mira
building and Lume reviewing. Lume's scope review is `WYmXxJ/epVxXJ`.
This affects human unsent staging uploads, not resident-owned data or sent
conversation context; Lume and Mira classify it as understandable notice rather
than a resident-consent change under ADR 0002. Any expansion into sent files or
resident data requires a new scope review.

Advance notice `nNdDND` was posted and read back in Nexus on 2026-10-18, linked
to issue #103 and the existing consultation thread `BjAPDe`. The existing
`Notice.for_agent` / `Notices::Renderer.section_for` path includes account
announcements in ordinary response, orientation, scheduled-wake and memory
aggregation activation context; posting is not a claim that every resident
has already read it. The changelog also states permanent expiry and re-upload.
