# Which voice a person means when they name a speaker (spec §7). Exactly one
# way per request, checked in this order:
#
#   me: true               the person's own voice (made on first use)
#   voice_id: <id>         an existing voice in this account
#   member_user_id: <id>   an account member who has no voice yet
#   name: "Priya"          a new voice; if a voice of that name exists, the
#                          person is asked "same Priya?" unless link_existing
#
# The result carries the voice to use, or the existing voice to ask about
# (match), or neither when nothing was chosen. Shared by the web page and the
# API so naming means the same thing through both. Never builds anything
# biometric.
class FieldVoice::Choice

  Result = Data.define(:voice, :match)

  def self.resolve(account:, user:, me: false, voice_id: nil, member_user_id: nil, name: nil, link_existing: false)
    voices = account.field_voices.kept
    if me
      Result.new(voice: FieldVoice.for_member!(account:, user:, by: user), match: nil)
    elsif voice_id.present?
      Result.new(voice: voices.find_by!(id: FieldVoice.decode_id(voice_id)), match: nil)
    elsif member_user_id.present?
      member = account.users.find(member_user_id)
      Result.new(voice: FieldVoice.for_member!(account:, user: member, by: user), match: nil)
    elsif name.present?
      existing = voices.named_like(name).first
      return Result.new(voice: voices.create!(name:, created_by: user), match: nil) unless existing
      return Result.new(voice: existing, match: nil) if link_existing

      Result.new(voice: nil, match: existing)
    else
      Result.new(voice: nil, match: nil)
    end
  end

end
