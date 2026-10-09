# What the web page and the API share for an account's transcription
# glossary: adding (or restoring) a term, pinning it, and removing it. Terms
# are named by their text, because built-in terms (resident names, the house's
# name) have no row until someone removes one.
module TranscriptionGlossaryActions

  extend ActiveSupport::Concern

  private

  def glossary_term_param
    value = params[:term]
    value.is_a?(String) ? value : nil
  end

  def glossary_pinned_param
    ActiveModel::Type::Boolean.new.cast(params[:pinned])
  end

  def glossary_payload(account)
    glossary = TranscriptionGlossary.new(account)
    {
      keyterm_limit: TranscriptionGlossary::KEYTERM_LIMIT,
      terms: glossary.entries.map(&:as_json),
      removed: glossary.suppressed.map { |record| record.as_json.merge(removed_at: record.suppressed_at) }
    }
  end

  # Pins or unpins an active term. A built-in term gets a row so the pin
  # sticks; it becomes manual, because a person chose it.
  def pin_glossary_term!(account, term, pinned:, by:)
    glossary = TranscriptionGlossary.new(account)
    entry = glossary.entries.find { |candidate| TranscriptionGlossaryTerm.normalize(candidate.term) == TranscriptionGlossaryTerm.normalize(term) }
    raise ActiveRecord::RecordNotFound unless entry

    return glossary.add!(entry.term, by:, pinned:) unless entry.record

    entry.record.update!(pinned:)
    entry.record
  end

end
