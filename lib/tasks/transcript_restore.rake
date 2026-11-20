namespace :backup do
  desc "What a resident's latest verified backup holds of its session transcripts (#969). Without EXPECT: a " \
       "metadata-only baseline (counts and bytes per transcript path; nothing restored or read). With " \
       "EXPECT=path=sha256,... (synthetic test files only): restore into a throwaway volume and check they came " \
       "back; REFUSE=path,... must not be in the snapshot. Paths are relative to the state volume."
  task :transcript_restore_check, [ :agent_id ] => :environment do |_task, args|
    agent = Agent.find(args.fetch(:agent_id))
    expect = ENV.fetch("EXPECT", "").split(",").map(&:strip).reject(&:blank?).to_h do |pair|
      path, digest = pair.split("=", 2)
      abort "EXPECT entries must be path=sha256" if digest.blank?
      [ path, digest ]
    end
    refuse = ENV.fetch("REFUSE", "").split(",").map(&:strip).reject(&:blank?)
    report = Backup::TranscriptRestoreCheck.new(agent, expect:, refuse:).call
    puts JSON.pretty_generate(report.to_h)
    exit(1) unless report.ok?
  end
end
