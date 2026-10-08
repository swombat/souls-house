# The production gate on "suggested from what's said" (spec §8, Mira on #215).
# Suggestions send transcript text, the title, the note and this Field's names
# through OpenRouter to Google Gemini. Until that processing is documented and
# its terms verified, the call is off unless the house turns it on in deploy
# configuration. Off means no inference is contacted at all.
module FieldSuggestions

  module_function

  def enabled? = ENV["SOULSHOUSE_FIELD_SUGGESTIONS"] == "on"

end
