# Transcripts where two diarized speakers were linked to one voice now read as
# one speaker (consecutive turns join). Re-render the ones already stored.
class RerenderTranscriptsWithMergedVoices < ActiveRecord::Migration[8.1]

  def up
    voice_ids = select_values(<<~SQL)
      SELECT DISTINCT field_voice_id FROM field_recording_speakers
      WHERE field_voice_id IS NOT NULL
      GROUP BY field_recording_id, field_voice_id
      HAVING count(*) > 1
    SQL
    voice_ids.each { |voice_id| FieldRecordings::RerenderTranscriptsJob.perform_later(voice_id) }
  end

  def down; end

end
