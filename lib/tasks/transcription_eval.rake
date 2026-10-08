namespace :transcription_eval do
  desc "Export voice-composed messages for the transcription eval. " \
       "SPEAKERS=a@x,b@y [OUT=tmp/transcription-eval] [SINCE=2026-06-01] [LIMIT=n]"
  task export: :environment do
    require Rails.root.join("lib/transcription_eval/exporter").to_s

    emails = ENV.fetch("SPEAKERS") { abort "SPEAKERS=email[,email] is required" }.split(",")
    out = ENV.fetch("OUT", Rails.root.join("tmp/transcription-eval").to_s)
    since = ENV["SINCE"].presence && Time.zone.parse(ENV["SINCE"])
    limit = ENV["LIMIT"].presence&.to_i

    count = TranscriptionEval::Exporter.new(out_dir: out, emails: emails, since: since, limit: limit).run
    puts "Exported #{count} voice messages to #{out}"
    puts "Pack with: tar czf transcription-eval.tgz -C #{File.dirname(out)} #{File.basename(out)}"
  end
end
