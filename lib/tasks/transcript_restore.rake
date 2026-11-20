namespace :backup do
  desc "Restore a resident's session transcripts from its latest verified backup into a throwaway volume and " \
       "report what came back (#969). EXPECT=path=sha256,... must come back; REFUSE=path,... must not. " \
       "Paths are relative to the state volume. Never reads a transcript."
  task :transcript_restore_check, [ :agent_id ] => :environment do |_task, args|
    agent = Agent.find(args.fetch(:agent_id))
    expect = ENV.fetch("EXPECT", "").split(",").map(&:strip).reject(&:blank?).to_h { it.split("=", 2) }
    refuse = ENV.fetch("REFUSE", "").split(",").map(&:strip).reject(&:blank?)
    report = Backup::TranscriptRestoreCheck.new(agent, expect:, refuse:).call
    puts JSON.pretty_generate(report.to_h)
    exit(1) unless report.ok?
  end
end
