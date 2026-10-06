# Shared JSON shapes for Field items on the web page.
module FieldItems

  module_function

  def file_json(file)
    url_helpers = Rails.application.routes.url_helpers
    {
      key: "file-#{file.to_param}",
      kind: "file",
      id: file.to_param,
      title: file.title,
      note: file.note,
      filename: file.filename,
      content_type: file.content_type,
      byte_size: file.byte_size,
      uploader_name: file.uploader_name,
      uploader_kind: file.uploader_kind,
      created_at: file.created_at.iso8601,
      download_url: (url_helpers.rails_blob_url(file.file, only_path: true, disposition: :attachment) if file.file.attached?)
    }
  end

  def note_json(note)
    {
      key: "note-#{note.to_param}",
      kind: "note",
      id: note.to_param,
      title: note.name,
      name: note.name,
      summary: note.summary,
      content: note.content,
      content_length: note.content.to_s.length,
      revision: note.revision,
      editor_name: note.editor_name,
      created_at: (note.last_edited_at || note.updated_at).iso8601,
      last_edited_at: note.last_edited_at&.strftime("%b %d at %l:%M %p")
    }
  end

end
