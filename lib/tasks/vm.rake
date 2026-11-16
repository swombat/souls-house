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

  desc "Move ONE resident from its server to a spare the house holds (eRyZBY). Dry run by default: every gate. " \
       "MODE=apply starts the move; REQUESTED_BY=<site admin email> is required. TARGET=<cpo-id> names the spare; " \
       "without it, the oldest running spare of the type the resident's plan names."
  task :move, [ :agent_id ] => :environment do |_task, args|
    agent = Agent.find(args.fetch(:agent_id))
    requested_by = User.find_by(email_address: ENV.fetch("REQUESTED_BY", ""))
    abort "REQUESTED_BY must be a site admin's email address" unless requested_by&.is_site_admin?

    spares = CloudProcurementOperation.spares.where(state: "provisioned")
    target = if ENV["TARGET"].present?
      spares.find_by(public_id: ENV["TARGET"])
    else
      type = ResidentEntitlement.find_by(agent_id: agent.id)&.tier_record&.server_type
      spares.where(server_type: type).order(:id).first
    end
    abort "No such spare is held" if target.nil?

    mover = Agents::ServerMove.new
    gates = mover.gates(agent, target)
    puts JSON.pretty_generate(target: target.slice(:public_id, :server_type, :location, :provider_server_id),
      gates: gates.map { |gate| { gate.name => gate.refusal || "ok" } })
    next unless ENV["MODE"] == "apply"

    begin
      move = mover.start!(agent, target:, requested_by:)
      puts "Started: #{move.public_id}. Follow it with bin/rails vm:moves"
    rescue Agents::ServerMove::Refused => error
      abort "Refused: #{error.message}"
    end
  end

  desc "Moves between servers: the newest ten. RELEASE=<vsm-id> lets the left-behind server and snapshot go; " \
       "REVERT=<vsm-id> REASON=... sends a moved resident back to its old server. Both need REQUESTED_BY."
  task moves: :environment do
    VmServerMove.order(id: :desc).limit(10).each do |move|
      puts JSON.generate(move.slice(:public_id, :agent_id, :phase, :source_server_id, :target_server_id,
        :snapshot_image_id, :phase_started_at, :verified_at, :failure, :revert_reason))
    end
    id = ENV["RELEASE"].presence || ENV["REVERT"].presence
    next unless id

    requested_by = User.find_by(email_address: ENV.fetch("REQUESTED_BY", ""))
    abort "REQUESTED_BY must be a site admin's email address" unless requested_by&.is_site_admin?
    move = VmServerMove.find_by!(public_id: id)
    begin
      if ENV["RELEASE"].present?
        Agents::ServerMove.new.release!(move, requested_by:)
      else
        Agents::ServerMove.new.revert!(move, requested_by:, reason: ENV["REASON"])
      end
      puts "#{move.public_id} is now #{move.reload.phase}"
    rescue Agents::ServerMove::Refused => error
      abort "Refused: #{error.message}"
    end
  end
end
