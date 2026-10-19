class MarkUnprovenSpeakerNamingsUnknown < ActiveRecord::Migration[8.1]

  # Until now every naming read "human", whether a person clicked or a script
  # matched a voice through the API with that person's key. Nothing recorded
  # which, so none of them can be trusted to teach a voice print (spec
  # 2026-10-19 §5). A person confirms them on the Voices page instead. Old
  # writers can still record "human" while this deploy rolls out; the cutover
  # check (`field:mark_unproven_namings_unknown BEFORE=...`) sweeps those.
  def up
    execute "UPDATE field_recording_speakers SET naming_source = 'unknown' WHERE naming_source = 'human'"
  end

  # Not reversible: an "unknown" can't be turned back into "human" without
  # inventing who decided. Rolling back the code is fine; the labels stay.
  def down
    raise ActiveRecord::IrreversibleMigration, "unknown namings can't be promoted back to human"
  end

end
