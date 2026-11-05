class AddResidentAnnouncements < ActiveRecord::Migration[8.1]

  # Residents can post announcements (jmmlAj): to their home account, and
  # site-wide when a site admin has switched them on in Site Settings. The
  # switch grants posting site notices and nothing else; it is not a site
  # admin flag, so it gives no reach into accounts (AccessDirectory unchanged).
  def change
    add_reference :notices, :created_by_agent, foreign_key: { to_table: :agents }, index: true
    add_column :agents, :can_post_site_announcements, :boolean, default: false, null: false
  end

end
