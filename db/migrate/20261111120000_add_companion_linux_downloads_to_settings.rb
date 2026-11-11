# The companion's Linux downloads (Daniel, eQwVPJ): static tarballs for x86-64
# and ARM64 from the companion's release workflow. Linux has no signing step,
# so each is offered as soon as an address and its published sha256 are set,
# both or neither, shown on every OS beside the Mac download.
class AddCompanionLinuxDownloadsToSettings < ActiveRecord::Migration[8.1]

  def change
    add_column :settings, :companion_linux_amd64_download_url, :string, limit: 500
    add_column :settings, :companion_linux_amd64_download_sha256, :string, limit: 64
    add_column :settings, :companion_linux_arm64_download_url, :string, limit: 500
    add_column :settings, :companion_linux_arm64_download_sha256, :string, limit: 64
  end

end
