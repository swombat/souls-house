# The versioned Linux installer script (install-linux.sh) from the companion's
# GitHub release, offered with its published sha256 on /companion as a
# download-to-temp-file one-liner alongside the manual tarballs.
class AddCompanionLinuxInstallerToSettings < ActiveRecord::Migration[8.1]

  def change
    add_column :settings, :companion_linux_installer_download_url, :string, limit: 500
    add_column :settings, :companion_linux_installer_download_sha256, :string, limit: 64
  end

end
