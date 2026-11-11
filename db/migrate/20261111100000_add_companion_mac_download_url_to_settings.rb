# Where the companion app's Mac download lives (#companion page, eQwVPJ).
# Blank means there is no signed, notarised build yet, and every download
# control reads "Mac download coming soon" instead of linking a file people
# can't open. A site admin fills it in from Site Admin once one exists.
class AddCompanionMacDownloadUrlToSettings < ActiveRecord::Migration[8.1]

  def change
    add_column :settings, :companion_mac_download_url, :string, limit: 500
    # An early, unsigned build people may choose knowingly (Daniel, eqRAMj
    # JBVBOD): its address and the sha256 published beside it, both or neither.
    add_column :settings, :companion_mac_early_download_url, :string, limit: 500
    add_column :settings, :companion_mac_early_download_sha256, :string, limit: 64
  end

end
