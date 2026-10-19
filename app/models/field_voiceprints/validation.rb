# The held-out check (spec 2026-10-19 §7; Mira's review of #474). For each
# recording R with eligible samples, every candidate print is rebuilt without
# any sample from R, and every eligible sample in R is matched against those
# prints with the production matcher.
#
# A print may guess only when, over its held-out queries, it has samples from
# at least two recordings, at least two correct and at least 80% of its own
# queries correct, and no false accept into it from at least ten other
# people's queries. A query whose own voice has no held-out print (a
# single-recording voice, say) still counts: any guess it gets is a false
# accept into the winner.
#
# Production matches only against the prints that may guess, so validation
# must too: a print that fails can't be left in as a competitor that absorbs
# a wrong match. Candidates start as every print in the cohort; each round
# drops those that fail, and the check repeats on the rest until every
# remaining print passes when measured against only the others that pass.
#
# Verdicts are stamped with the cohort digest (FieldVoiceprints::Cohort) and
# published under every voice lock in the account, only if the cohort is
# still the one measured.
module FieldVoiceprints::Validation

  MIN_RECORDINGS = 2
  MIN_CORRECT = 2
  MIN_ACCURACY = 0.8
  MIN_NEGATIVES = 10

  module_function

  # Returns {voice_id => stats}, or nil when the cohort changed meanwhile (the
  # caller checks again later).
  def run!(account)
    prints = FieldVoiceprints::Cohort.prints(account)
    digest = FieldVoiceprints::Cohort.digest(prints)
    stats, passing = measure(account, prints)

    published = ApplicationRecord.transaction do
      FieldVoice.where(account:).order(:id).lock.to_a
      live = FieldVoiceprints::Cohort.prints(account)
      next false unless FieldVoiceprints::Cohort.digest(live) == digest

      live.each do |print|
        print.update!(validated: passing.include?(print.field_voice_id), validated_digest: digest,
          validation: stats.fetch(print.field_voice_id, {}))
      end
      true
    end
    published ? stats : nil
  end

  def passes?(entry, print)
    print.recording_count >= MIN_RECORDINGS && entry["correct"] >= MIN_CORRECT &&
      entry["correct"] >= MIN_ACCURACY * entry["queries"] && entry["false_accepts_into"].zero? &&
      entry["negatives"] >= MIN_NEGATIVES
  end

  # [{voice_id => stats}, Set of voice ids that pass]. Stats are each print's
  # from the last round it was a candidate in.
  def measure(account, prints)
    return [ {}, Set.new ] if prints.empty?

    profile = prints.max_by(&:updated_at).profile
    by_voice = prints.index_by(&:field_voice_id)
    samples = FieldVoiceSample.eligible.where(account:, field_voice_id: by_voice.keys, profile:).to_a
    vectors = samples.to_h { |sample| [ sample.id, sample.vector ] }
    candidates = by_voice.select { |_, print| print.profile == profile }.keys.to_set
    final = {}

    loop do
      stats = evaluate(samples, vectors, candidates)
      final.merge!(stats)
      passing = candidates.select { |voice_id| passes?(stats.fetch(voice_id), by_voice.fetch(voice_id)) }.to_set
      return [ final, passing ] if passing == candidates

      candidates = passing
    end
  end

  def evaluate(samples, vectors, candidates)
    stats = candidates.to_h do |voice_id|
      [ voice_id, { "queries" => 0, "correct" => 0, "rejected" => 0, "wrong" => 0, "false_accepts_into" => 0,
                    "negatives" => 0 } ]
    end
    samples.group_by(&:field_recording_id).each do |recording_id, queries|
      held_out = samples.reject { |sample| sample.field_recording_id == recording_id }
        .select { |sample| candidates.include?(sample.field_voice_id) }
        .group_by(&:field_voice_id)
        .to_h { |voice_id, own| [ voice_id, FieldVoiceprints.centroid(own.map { |sample| vectors[sample.id] }) ] }
        .compact
      guesses = FieldVoiceprints::Matching.guesses(queries.to_h { |sample| [ sample.id, vectors[sample.id] ] }, held_out)

      queries.each do |query|
        held_out.each_key { |voice_id| stats[voice_id]["negatives"] += 1 unless voice_id == query.field_voice_id }
        guess = guesses[query.id]&.first
        if held_out.key?(query.field_voice_id)
          entry = stats[query.field_voice_id]
          entry["queries"] += 1
          if guess.nil?
            entry["rejected"] += 1
          elsif guess == query.field_voice_id
            entry["correct"] += 1
          else
            entry["wrong"] += 1
            stats[guess]["false_accepts_into"] += 1
          end
        elsif guess
          stats[guess]["false_accepts_into"] += 1
        end
      end
    end
    stats
  end

end
