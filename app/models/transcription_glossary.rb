# An account's transcription glossary: the terms its members and residents
# keep, plus built-in ones (the account's resident names and the site's own
# name, Setting#site_name), minus anything removed. `keyterms` is what goes to Scribe.
#
# Keyterms cost a 20% surcharge, and over 100 of them a 20-second minimum
# billable duration applies per request, so at most 100 are sent. Every
# account's glossary is used; if ElevenLabs refuses the keyterms, the
# transcription is retried once without them (ElevenLabsStt, ElevenLabsScribe).
class TranscriptionGlossary

  KEYTERM_LIMIT = 100
  # Order for the 100-term cut: pinned first, then by how the term arrived.
  SOURCE_RANK = { "manual" => 0, "built_in" => 1, "correction" => 2, "harvested" => 3 }.freeze

  Entry = Data.define(:term, :source, :pinned, :record) do
    def as_json(*)
      return record.as_json.merge(built_in: false) if record

      { id: nil, term:, source:, pinned:, built_in: true }
    end
  end

  def self.keyterms_for(account)
    return [] unless account

    new(account).keyterms
  rescue StandardError => e
    # The glossary must never stop a transcription.
    Rails.logger.warn("[TranscriptionGlossary] keyterms unavailable for account #{account&.id}: #{e.class}")
    []
  end

  def initialize(account)
    @account = account
  end

  # Every active term, built-ins included, in keyterm priority order.
  def entries
    stored = @account.transcription_glossary_terms.includes(:created_by_user, :created_by_agent).to_a
    taken = stored.map(&:normalized_term).to_set
    active = stored.reject(&:suppressed?).map { |record| Entry.new(record.term, record.source, record.pinned, record) }

    built_in = built_in_terms.filter_map do |term|
      normalized = TranscriptionGlossaryTerm.normalize(term)
      next if taken.include?(normalized)

      taken << normalized
      Entry.new(term, "built_in", false, nil)
    end

    (active + built_in).sort_by.with_index do |entry, index|
      [ entry.pinned ? 0 : 1, SOURCE_RANK.fetch(entry.source), -(entry.record&.last_seen_at || entry.record&.created_at || Time.at(0)).to_f, index ]
    end
  end

  def keyterms
    entries.map(&:term).first(KEYTERM_LIMIT)
  end

  def suppressed
    @account.transcription_glossary_terms.suppressed.order(suppressed_at: :desc)
  end

  # Adds or restores a term on someone's explicit say-so. An explicit add
  # lifts a tombstone and makes the term manual: a person's choice outranks
  # whatever automation did before.
  def add!(term, by:, pinned: false)
    record = find_or_initialize(term)
    record.assign_attributes(
      term: TranscriptionGlossaryTerm.clean(term),
      source: "manual",
      suppressed_at: nil,
      pinned: pinned || (record.persisted? && !record.suppressed? && record.pinned)
    )
    record.created_by_user ||= by if by.is_a?(User)
    record.created_by_agent ||= by if by.is_a?(Agent)
    record.save!
    record
  end

  # Removes a term, built-in or stored, leaving a tombstone.
  def remove!(term, by:)
    record = find_or_initialize(term)
    if record.new_record?
      record.term = TranscriptionGlossaryTerm.clean(term)
      record.source = "manual"
    end
    record.created_by_user ||= by if by.is_a?(User)
    record.created_by_agent ||= by if by.is_a?(Agent)
    record.suppressed_at = Time.current
    record.pinned = false
    record.save!
    record
  end

  private

  def find_or_initialize(term)
    @account.transcription_glossary_terms.find_or_initialize_by(normalized_term: TranscriptionGlossaryTerm.normalize(term))
  end

  def built_in_terms
    names = @account.agents.active.pluck(:name)
    (names + [ Setting.instance.site_name ]).map { |name| TranscriptionGlossaryTerm.clean(name) }
      .select { |name| name.present? && name.length <= TranscriptionGlossaryTerm::MAX_LENGTH && name.split.size <= TranscriptionGlossaryTerm::MAX_WORDS && !name.match?(TranscriptionGlossaryTerm::FORBIDDEN_CHARACTERS) }
      .uniq { |name| TranscriptionGlossaryTerm.normalize(name) }
  end

end
