namespace :vm do
  desc "Disposable restore check for a resident on its own VM (#246): seed files and checkpoint come back from its backup"
  task :restore_check, [ :agent_id ] => :environment do |_task, args|
    agent = Agent.find(args.fetch(:agent_id))
    report = Backup::VmRestoreCheck.new(agent).call
    puts JSON.pretty_generate(report.to_h)
    exit(1) unless report.ok?
  end

  desc "Move ONE named house resident to its own server (#426 slice 3B). Dry run by default: every gate and each " \
       "role's size against the seed limits. MODE=apply stages and admits it through the same gates; " \
       "REQUESTED_BY=<site admin email> is required for both."
  task :migrate, [ :agent_id ] => :environment do |_task, args|
    agent = Agent.find(args.fetch(:agent_id))
    requested_by = User.find_by(email_address: ENV.fetch("REQUESTED_BY", ""))
    abort "REQUESTED_BY must be a site admin's email address" unless requested_by&.is_site_admin?

    migration = Agents::VmMigration.new(agent)
    report = Agents::VmMigration::Plan.new(migration).call(measure: ENV["MEASURE"] != "0", requested_by:)
    puts JSON.pretty_generate(report.to_h)
    next unless ENV["MODE"] == "apply"

    begin
      placement = migration.move!(requested_by:)
      puts "Staged and admitted: placement #{placement.id}, generation #{placement.reload.generation}"
    rescue Agents::VmMigration::Refused => error
      abort "Refused: #{error.message}"
    end
  end

  desc "Spare servers (eRyZBY): what is waiting, wanted and held. RELEASE=<cpo-id> REQUESTED_BY=<site admin email> " \
       "deletes one spare at Hetzner."
  task spares: :environment do
    puts JSON.pretty_generate(SpareServers.new.status)
    next unless ENV["RELEASE"].present?

    requested_by = User.find_by(email_address: ENV.fetch("REQUESTED_BY", ""))
    abort "REQUESTED_BY must be a site admin's email address" unless requested_by&.is_site_admin?
    operation = CloudProcurementOperation.spares.find_by!(public_id: ENV["RELEASE"])
    operation = CloudProcurement.from_credentials.request_delete!(operation, requested_by:)
    CloudProcurementReconcileJob.perform_later(operation.id)
    puts "Release asked: #{operation.public_id} is #{operation.state}"
  end
end
