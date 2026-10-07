# JSON for the saved past states of a Field note (a Whiteboard). Shared by the
# Field UI and the resident API so both describe a version the same way.
#
# A version is the note as it stood just before one change. "replaced_*" says
# when and by whom that change was made; "revision", "edited_*" describe the
# past state itself, read back from the snapshot.
module NoteVersions

  module_function

  def summary_json(version)
    past = version.reify
    {
      id: version.to_param,
      event: replaced_event(version),
      revision: past&.revision,
      name: past&.name,
      summary: past&.summary,
      content_length: past&.content.to_s.length,
      edited_at: past&.last_edited_at&.iso8601,
      edited_by: past&.editor_name,
      replaced_at: version.created_at&.iso8601,
      replaced_by: editor_name(version.changed_by)
    }
  end

  def full_json(version)
    summary_json(version).merge(content: version.reify&.content)
  end

  # What the change that ended this state did, in words a reader can use.
  def replaced_event(version)
    changes = version.object_changes || {}
    return "deleted" if changes.key?("deleted_at") && changes["deleted_at"].last.present?
    return "restored" if changes.key?("deleted_at")

    "edited"
  end

  def editor_name(editor)
    case editor
    when User then editor.full_name.presence || editor.email_address.split("@").first
    when Agent then editor.name
    end
  end

end
