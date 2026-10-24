# One role's home (identity, repo or work) from an archive import, kept in the
# house until a VM is seeded from it (docs/2026-10-10-vm-imports.md, point 10).
#
# The bytes are a gzip tarball of the role's tree, built once from the
# validated archive and stored with its digest, so every later seed_home for
# the role names the same bytes. A stage belongs to the resident, not to its
# placement: it outlives a released server and a retried Activate. It holds no
# server and no cap slot.
class AgentImportStage < ApplicationRecord

  ROLES = Agents::Portability::Archive::ROOTS

  belongs_to :agent, inverse_of: :import_stages

  validates :role, inclusion: { in: ROLES }, uniqueness: { scope: :agent_id }
  validates :archive, :sha256, presence: true
  validates :sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :bytes, numericality: { only_integer: true, greater_than: 0 }
  validate :digest_matches

  private

  def digest_matches
    return if archive.blank?

    errors.add(:bytes, "does not match the archive") unless bytes == archive.bytesize
    errors.add(:sha256, "does not match the archive") unless sha256 == Digest::SHA256.hexdigest(archive)
  end

end
