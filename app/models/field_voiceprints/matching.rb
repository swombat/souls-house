# Who a probe sounds like (spec 2026-10-19 §8), the one matcher used both by
# Identification on real recordings and by Validation on held-out ones, so the
# accuracy measured is the accuracy shipped.
#
# A probe gets a guess when its best print scores at least the recipe's
# threshold and leads the runner-up by its margin. Two probes from one
# recording that pick the same voice both stay unguessed unless both reach
# the split threshold (the transcriber heard one person as two), as the
# Mac's identify.py does. A guess is sure (`sure?`) when it also clears the
# recipe's naming line; Identification names such a speaker without a tap
# when the print is validated and the account allows it.
module FieldVoiceprints::Matching

  module_function

  # probes: {key => vector}; prints: {voice_id => vector}, same profile.
  # Returns {key => [voice_id, score, lead]} for the probes that get a guess,
  # lead being the score minus the runner-up's.
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

      [ key, [ voice_id, top, top - second ] ]
    end.to_h

    best.group_by { |_, (voice_id, _)| voice_id }.each_value do |claims|
      next if claims.size < 2
      next if claims.all? { |_, (_, score)| score >= recipe[:split] }

      claims.each { |key, _| best.delete(key) }
    end
    best
  end

  # A guess from `guesses` that clears the naming line.
  def sure?(guess, profile: FieldVoiceprints::Profiles.configured)
    return false unless guess

    recipe = FieldVoiceprints::Profiles.recipe(profile)
    _voice_id, score, lead = guess
    score >= recipe[:name_threshold] && lead.to_f >= recipe[:name_margin]
  end

end
