# Who a probe sounds like (spec 2026-10-19 §8), the one matcher used both by
# Identification on real recordings and by Validation on held-out ones, so the
# accuracy measured is the accuracy shipped.
#
# A probe gets a guess when its best print scores at least MATCH_THRESHOLD
# and leads the runner-up by MATCH_MARGIN. Two probes from one recording that
# pick the same voice both stay unguessed unless both reach SPLIT_THRESHOLD
# (the transcriber heard one person as two), as the Mac's identify.py does.
module FieldVoiceprints::Matching

  module_function

  # probes: {key => vector}; prints: {voice_id => vector}, same profile.
  # Returns {key => [voice_id, score]} for the probes that get a guess.
  def guesses(probes, prints, profile: FieldVoiceprints::Profiles.configured)
    return {} if prints.empty?
    recipe = FieldVoiceprints::Profiles.recipe(profile)
    return {} unless prints.values.all? { |vector| FieldVoiceprints::Profiles.valid_vector?(vector, profile) }

    best = probes.filter_map do |key, vector|
      next unless FieldVoiceprints::Profiles.valid_vector?(vector, profile)

      scored = prints.map { |voice_id, print| [ voice_id, FieldVoiceprints.cosine(vector, print) ] }.sort_by { |_, score| -score }
      voice_id, top = scored.first
      second = scored[1]&.last || 0.0
      next unless top >= recipe[:threshold] && top - second >= recipe[:margin]

      [ key, [ voice_id, top ] ]
    end.to_h

    best.group_by { |_, (voice_id, _)| voice_id }.each_value do |claims|
      next if claims.size < 2
      next if claims.all? { |_, (_, score)| score >= recipe[:split] }

      claims.each { |key, _| best.delete(key) }
    end
    best
  end

end
