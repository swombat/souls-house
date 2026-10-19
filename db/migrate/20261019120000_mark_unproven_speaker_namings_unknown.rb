class MarkUnprovenSpeakerNamingsUnknown < ActiveRecord::Migration[8.1]

  # Until now every naming read "human", whether a person clicked or a script
  # matched a voice through the API with that person's key. Nothing recorded
  # which, so none of them can be trusted to teach a voice print (spec
  # 2026-10-19 §5). A person confirms them on the Voices page instead.
  def up
    execute "UPDATE field_recording_speakers SET naming_source = 'unknown' WHERE naming_source = 'human'"
  end

  def down
    execute "UPDATE field_recording_speakers SET naming_source = 'human' WHERE naming_source = 'unknown'"
  end

end
