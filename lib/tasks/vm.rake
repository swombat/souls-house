namespace :vm do
  desc "Disposable restore check for a resident on its own VM (#246): seed files and checkpoint come back from its backup"
  task :restore_check, [ :agent_id ] => :environment do |_task, args|
    agent = Agent.find(args.fetch(:agent_id))
    report = Backup::VmRestoreCheck.new(agent).call
    puts JSON.pretty_generate(report.to_h)
    exit(1) unless report.ok?
  end
end
