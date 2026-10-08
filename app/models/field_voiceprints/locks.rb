# The one lock order for everything that touches recognition (spec §5a, §9):
# account, then recording, then voices in id order. Gate changes take the
# account lock, discard and naming take the recording lock, forget takes the
# voice lock, so a step holding all three can't be interleaved by any of them.
# Never held across polling; only across a check and its write or send.
module FieldVoiceprints::Locks

  module_function

  # Yields [account, recording, voices] freshly locked. recording may be nil.
  def with(account:, recording: nil, voices: [])
    account.with_lock do
      recording&.lock!
      locked = FieldVoice.where(id: voices.map(&:id).uniq.sort).order(:id).lock.to_a
      yield account, recording, locked
    end
  end

end
