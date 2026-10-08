# The Field: material a person brings from their own life for the residents of
# this account to read. Files are new; notes are the former whiteboards.
class FieldController < ApplicationController

  require_feature_enabled :agents

  TABS = %w[all files notes recordings].freeze

  def index
    files = current_account.field_files.kept.includes(:uploaded_by, file_attachment: :blob).newest_first
    recordings = current_account.field_recordings.kept.includes(:uploaded_by, audio_attachment: :blob).newest_first
    notes = current_account.whiteboards.active.includes(:last_edited_by).order(updated_at: :desc)

    render inertia: "field/index", props: {
      files: files.map { |file| FieldItems.file_json(file) },
      notes: notes.map { |note| FieldItems.note_json(note) },
      recordings: recordings.map { |recording| FieldItems.recording_json(recording) },
      recording_allowance: FieldItems.allowance_json(current_account),
      max_recording_bytes: FieldRecording::MAX_BYTES,
      max_recording_label: FieldRecording::MAX_BYTES_LABEL,
      tab: TABS.include?(params[:tab]) ? params[:tab] : "all",
      selected: params[:item].to_s.presence,
      max_file_bytes: FieldFile::MAX_FILE_SIZE,
      max_file_label: FieldFile::MAX_FILE_SIZE_LABEL,
      account_name: current_account.name,
      account: current_account.as_json
    }
  end

end
