# The runner bytes a birth's user_data pins (#779). Rendered user_data no
# longer carries the runner; it carries this digest, and the VM fetches the
# bytes from Api::V1::HostRunner::BirthBundlesController before enrolling.
# Stored by digest so a release between render and fetch changes nothing for
# a VM already being born; the first heartbeat after enroll brings it current
# through update_runner.
class RunnerBirthBundle < ApplicationRecord

  validates :sha256, format: { with: RunnerBundle::DIGEST }
  validates :bytes, presence: true

  # Pins the current bundle to this enrollment and returns its digest. Drops
  # blobs no unenrolled, unrevoked, unexpired enrollment still pins.
  def self.pin!(enrollment, bundle: RunnerBundle.current, now: Time.current)
    begin
      find_or_create_by!(sha256: bundle.sha256) { |row| row.bytes = bundle.bytes }
    rescue ActiveRecord::RecordNotUnique
      retry
    end
    enrollment.update!(birth_bundle_sha256: bundle.sha256)
    pinned = RunnerEnrollment.where(enrolled_at: nil, revoked_at: nil).where("expires_at > ?", now)
      .where.not(birth_bundle_sha256: nil).select(:birth_bundle_sha256)
    where.not(sha256: pinned).delete_all
    bundle.sha256
  end

end
