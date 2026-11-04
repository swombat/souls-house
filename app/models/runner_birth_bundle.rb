# The runner bytes a birth's user_data pins (#779). Rendered user_data no
# longer carries the runner; it carries this digest, and the VM fetches the
# bytes from Api::V1::HostRunner::BirthBundlesController before enrolling.
# Stored by digest so a release between render and fetch changes nothing for
# a VM already being born; the first heartbeat after enroll brings it current
# through update_runner.
class RunnerBirthBundle < ApplicationRecord

  # A blob no enrollment pins survives this long after its last pin!, so a
  # prune never deletes one that another birth has reused but whose
  # enrollment pin is not yet visible.
  PRUNE_GRACE = 1.hour

  validates :sha256, format: { with: RunnerBundle::DIGEST }
  validates :bytes, presence: true

  # Pins the current bundle to this enrollment and returns its digest. The
  # upsert (re)creates the blob or refreshes its updated_at in one statement,
  # before the pin: a concurrent prune either ran first (and the upsert
  # recreates the row) or rechecks updated_at on the refreshed row and keeps
  # it. Then drops blobs that no unenrolled, unrevoked, unexpired enrollment
  # pins and that nothing has pinned within PRUNE_GRACE.
  def self.pin!(enrollment, bundle: RunnerBundle.current, now: Time.current)
    record = new(sha256: bundle.sha256, bytes: bundle.bytes)
    raise ActiveRecord::RecordInvalid, record unless record.valid?
    upsert({ sha256: bundle.sha256, bytes: bundle.bytes, created_at: now, updated_at: now },
      unique_by: :sha256, on_duplicate: Arel.sql("updated_at = EXCLUDED.updated_at"), record_timestamps: false)
    enrollment.update!(birth_bundle_sha256: bundle.sha256)
    pinned = RunnerEnrollment.where(enrolled_at: nil, revoked_at: nil).where("expires_at > ?", now)
      .where.not(birth_bundle_sha256: nil).select(:birth_bundle_sha256)
    where.not(sha256: pinned).where("updated_at < ?", now - PRUNE_GRACE).delete_all
    bundle.sha256
  end

end
