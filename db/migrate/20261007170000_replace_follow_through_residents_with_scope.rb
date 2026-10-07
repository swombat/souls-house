# The follow-through switch moves from a typed list of ids to a scope on the
# site setting ("off", "selected", "all") plus a flag on each resident, so the
# admin page can offer a picker. Any list already saved is carried over.
class ReplaceFollowThroughResidentsWithScope < ActiveRecord::Migration[8.1]

  def up
    add_column :settings, :follow_through_scope, :string, default: "off", null: false
    add_column :agents, :follow_through, :boolean, default: false, null: false

    saved = select_value("SELECT follow_through_residents FROM settings ORDER BY id LIMIT 1").to_s.strip
    if saved == "all"
      execute "UPDATE settings SET follow_through_scope = 'all'"
    elsif saved.present?
      ids = saved.split(",").map(&:strip).reject(&:empty?).filter_map do |param|
        Agent.decode_id(param) # the salt is keyed to the Agent class name
      rescue StandardError
        nil
      end
      if ids.any?
        execute "UPDATE agents SET follow_through = TRUE WHERE id IN (#{ids.map { |id| Integer(id) }.join(",")})"
        execute "UPDATE settings SET follow_through_scope = 'selected'"
      end
    end

    remove_column :settings, :follow_through_residents
  end

  def down
    add_column :settings, :follow_through_residents, :string, default: "", null: false
    remove_column :agents, :follow_through
    remove_column :settings, :follow_through_scope
  end

end
