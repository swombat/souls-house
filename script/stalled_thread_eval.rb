# Scores a stalled-thread dataset with Jev. Reads pairs of (chat, as_of)
# from the file named by PAIRS (JSON array of {"chat":..,"as_of":..}),
# rebuilds each snapshot with StalledThreadSnapshot as the sweeper would
# have seen it STALE_HOURS after that message, asks the sweeper's questions
# and prints one JSON line per pair: {chat, as_of, scores: {key: score}} or
# {chat, as_of, error: ...}. No labels are read here; scoring is offline.
#
#   PAIRS=/tmp/pairs.json STALE_HOURS=2 bin/rails runner script/stalled_thread_eval.rb > scores.jsonl

pairs = JSON.parse(File.read(ENV.fetch("PAIRS")))
stale = ENV.fetch("STALE_HOURS", "2").to_f.hours

pairs.each do |pair|
  chat = Chat.find_by_obfuscated_id(pair["chat"])
  message = chat && Message.find_by_obfuscated_id(pair["as_of"])
  unless chat && message && message.chat_id == chat.id
    puts({ chat: pair["chat"], as_of: pair["as_of"], error: "not found" }.to_json)
    next
  end
  snapshot = StalledThreadSnapshot.new(chat, as_of: message, now: message.created_at + stale)
  questions = StalledThreadSweeperQuestions.for(chat)
  names = chat.agents.each_with_object({}) { |a, h| h[StalledThreadSweeperQuestions.wake_key(a)] = "wake:#{a.name}" }
  begin
    answers = UtilityInference.decide(state: snapshot.state, questions: questions)
    scores = answers.transform_keys { |k| names[k] || k }
    puts({ chat: pair["chat"], as_of: pair["as_of"], scores: scores }.to_json)
  rescue UtilityInference::Error => error
    puts({ chat: pair["chat"], as_of: pair["as_of"], error: error.class.name }.to_json)
    sleep 2 if error.is_a?(UtilityInference::RateLimited)
  end
  $stdout.flush
end
