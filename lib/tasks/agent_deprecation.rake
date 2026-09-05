namespace :agents do
  desc "Print non-secret legacy runtime inventory; makes no changes"
  task deprecation_inventory: :environment do
    puts JSON.pretty_generate(Agents::DeprecateInline.inventory)
  end

  desc "Deprecate explicitly reviewed inline IDs (REVIEWED_IDS=1,2 CONFIRM=deprecate-inline)"
  task deprecate_inline: :environment do
    abort "Set CONFIRM=deprecate-inline after reviewing the inventory" unless ENV["CONFIRM"] == "deprecate-inline"
    ids = ENV.fetch("REVIEWED_IDS").split(",")
    puts JSON.generate(deprecated_ids: Agents::DeprecateInline.call(expected_ids: ids))
  end
end
