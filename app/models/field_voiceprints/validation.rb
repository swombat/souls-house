# The held-out check (spec 2026-10-19 §7). For each recording R that has
# eligible samples, every print is rebuilt without any sample from R, and R's
# samples are matched against those prints with the production matcher.
#
# A print may guess only when, over its held-out queries, it has samples from
# at least two recordings, at least two correct and at least 80% of its own
# queries correct, and no false accept into it from at least ten other
# people's queries. Anything less is "not yet checked" and makes no guesses.
#
# Results are stamped with the sample set they were computed on
# (validated_digest); a print rebuilt since is inactive until this runs again.
module FieldVoiceprints::Validation

  MIN_RECORDINGS = 2
  MIN_CORRECT = 2
  MIN_ACCURACY = 0.8
  MIN_NEGATIVES = 10

  module_function

  # Returns {voice_id => stats}. Writes each print's verdict under its voice
  # lock, only if its samples haven't changed since they were read.
  def run!(account)
    prints = FieldVoiceprint.joins(:field_voice).merge(FieldVoice.kept).where(account:).to_a
    return {} if prints.empty?

    stats = measure(account, prints)
    prints.each do |print|
      voice = print.field_voice
      voice.with_lock do
        live = FieldVoiceprint.find_by(id: print.id)
        next unless live && live.sample_digest == print.sample_digest && live.generation == voice.print_generation

        entry = stats.fetch(voice.id)
        live.update!(validated: passes?(entry, live), validated_digest: live.sample_digest, validation: entry)
      end
    end
    stats
  end

  def passes?(entry, print)
    print.recording_count >= MIN_RECORDINGS && entry["correct"] >= MIN_CORRECT &&
      entry["correct"] >= MIN_ACCURACY * entry["queries"] && entry["false_accepts_into"].zero? &&
      entry["negatives"] >= MIN_NEGATIVES
  end

  # Leave-one-recording-out over the samples the prints are built from.
  def measure(account, prints)
    profiles = prints.to_h { |print| [ print.field_voice_id, print.profile ] }
    samples = FieldVoiceSample.eligible.where(account:, field_voice_id: profiles.keys).to_a
      .select { |sample| profiles[sample.field_voice_id] == sample.profile }
    vectors = samples.to_h { |sample| [ sample.id, sample.vector ] }
    stats = profiles.keys.to_h do |voice_id|
      [ voice_id, { "queries" => 0, "correct" => 0, "rejected" => 0, "wrong" => 0, "false_accepts_into" => 0,
                    "negatives" => 0 } ]
    end

    samples.group_by(&:field_recording_id).each do |recording_id, queries|
      references = samples.reject { |sample| sample.field_recording_id == recording_id }.group_by(&:field_voice_id)
      by_profile = references.group_by { |voice_id, _| profiles[voice_id] }
      queries.group_by(&:profile).each do |profile, same_profile|
        held_out = (by_profile[profile] || []).to_h do |voice_id, own|
          [ voice_id, FieldVoiceprints.centroid(own.map { |sample| vectors[sample.id] }) ]
        end.compact
        guesses = FieldVoiceprints::Matching.guesses(same_profile.to_h { |sample| [ sample.id, vectors[sample.id] ] }, held_out)

        same_profile.each do |query|
          held_out.each_key { |voice_id| stats[voice_id]["negatives"] += 1 unless voice_id == query.field_voice_id }
          next unless held_out.key?(query.field_voice_id)

          entry = stats[query.field_voice_id]
          entry["queries"] += 1
          guess = guesses[query.id]&.first
          if guess.nil?
            entry["rejected"] += 1
          elsif guess == query.field_voice_id
            entry["correct"] += 1
          else
            entry["wrong"] += 1
            stats[guess]["false_accepts_into"] += 1
          end
        end
      end
    end
    stats
  end

end
