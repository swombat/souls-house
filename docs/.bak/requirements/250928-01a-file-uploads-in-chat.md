Ok, so currently we have a decent chat system... but it does not support file uploads.

RubyLLM supports attaching files and images and even audio files, as documented at: https://rubyllm.com/chat/#multi-modal-conversations

Please design a spec for adding file uploads to the chat system.

This should be done by either dragging and dropping files into the message input field, or by clicking a paperclip button in the message input field.

The file should be uploaded directly to S3 if that's possible (this would be possible with Turbo - not sure how easy it is in Svelte...) and then passed to RubyLLM for processing.

Files should be attached to a specific message (which then links them to a chat and to an account).

When a file is attached to a message sent by the user, the file should be displayed in the message display field (in the chat window that shows the whole conversation) with an appropriate icon.

## Clarifications

1. **File size and count limits**: 50MB maximum file size limit. Multiple files can be attached to a single message.
2. **File type restrictions**: Restrict to known image types (PNG, JPG, GIF, etc.), audio formats (MP3, WAV, etc.), video formats (MP4, MOV, etc.), and document types (PDF, Word, etc.).
3. **Display strategy**: Show all file types as an icon with filename. When clicked, the file loads/downloads.
4. **Upload approach**: Direct S3 upload if possible without too much complexity. If that's too complex, upload via Rails server with ActiveStorage.
5. **File lifecycle**: Files attached to deleted messages should be soft-deleted using the discard gem functionality.
6. **File availability**: Files should be downloadable by clicking on them.