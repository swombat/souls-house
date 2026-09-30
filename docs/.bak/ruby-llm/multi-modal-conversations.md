# RubyLLM Multi-Modal Conversations

## Version Information
- Documentation version: Latest (v1.7.0+)
- Source: https://rubyllm.com/chat/ and https://rubyllm.com/rails/
- Fetched: 2025-10-05

## Key Concepts

- **Multi-Modal Support**: Handle text, images, videos, audio, PDFs, and documents
- **Attachments vs Files**: Use attachments (not files!) for proper handling
- **ActiveStorage Integration**: Seamless file management with Rails
- **extract_content Method**: Automatic content extraction from various file types
- **Streaming with Attachments**: Real-time responses while processing files

## Implementation Guide

### 1. Model Setup for Attachments

```ruby
# app/models/message.rb
class Message < ApplicationRecord
  acts_as_message
  has_many_attached :attachments  # ActiveStorage integration

  # Optional: validate attachment types
  validates :attachments, content_type: {
    in: %w[
      image/png image/jpeg image/gif image/webp
      video/mp4 video/quicktime video/webm
      audio/mpeg audio/wav audio/ogg
      application/pdf
      text/plain text/csv
    ],
    message: 'File type not supported'
  }
end
```

### 2. Sending Messages with Attachments

#### Basic File Attachment

```ruby
# Using file path
chat.ask("Describe this image", with: "path/to/image.jpg")

# Using uploaded file in Rails controller
def send_message
  @chat = current_user.chats.find(params[:id])

  response = @chat.ask(
    params[:message],
    with: params[:attachment]  # File from form upload
  )

  redirect_to @chat
end
```

#### Multiple Attachments

```ruby
# Multiple files
chat.ask(
  "Compare these documents",
  with: ["document1.pdf", "document2.pdf", "chart.png"]
)

# In Rails with multiple uploads
response = @chat.ask(
  params[:message],
  with: params[:attachments]  # Array of uploaded files
)
```

#### Different File Types

```ruby
# Image analysis
chat.ask("What's in this image?", with: "photo.jpg")

# PDF document analysis
chat.ask("Summarize this document", with: "report.pdf")

# Audio transcription and analysis
chat.ask("Transcribe and analyze this audio", with: "meeting.mp3")

# Video analysis
chat.ask("Describe what happens in this video", with: "demo.mp4")

# Code file review
chat.ask("Review this code for bugs", with: "app.rb")
```

### 3. extract_content Method

The `extract_content` method automatically extracts text content from various file types:

```ruby
# Automatic content extraction
message = chat.ask("Analyze this", with: "document.pdf")

# Access extracted content
content = message.extract_content
puts content  # Returns extracted text from PDF

# Works with various file types
image_content = message.extract_content  # Image description
audio_content = message.extract_content  # Audio transcription
text_content = message.extract_content   # Raw text content
```

#### Manual Content Extraction

```ruby
# Extract content from attachment
attachment = message.attachments.first
extracted_text = RubyLLM.extract_content(attachment)

# With options
extracted_text = RubyLLM.extract_content(
  attachment,
  format: :text,
  language: :en
)
```

### 4. Streaming with Attachments

```ruby
# Stream responses while processing attachments
chat.ask("Analyze this large document", with: "large_file.pdf") do |chunk|
  print chunk.content
  # Real-time updates as AI processes the file
end

# In Rails with Turbo Streams
def stream_analysis
  @chat = current_user.chats.find(params[:id])

  response = @chat.ask(params[:message], with: params[:file]) do |chunk|
    # Broadcast real-time updates
    broadcast_append_to(
      @chat,
      target: "messages",
      partial: "chats/chunk",
      locals: { content: chunk.content }
    )
  end
end
```

### 5. Rails Form Integration

#### HTML Form for File Upload

```erb
<!-- app/views/chats/show.html.erb -->
<%= form_with url: chat_ask_path(@chat), local: false, multipart: true do |f| %>
  <div class="form-group">
    <%= f.text_area :message, placeholder: "Type your message...", required: true %>
  </div>

  <div class="form-group">
    <%= f.file_field :attachment, accept: "image/*,video/*,audio/*,.pdf,.txt,.csv" %>
    <small>Supported: Images, Videos, Audio, PDFs, Text files</small>
  </div>

  <%= f.submit "Send", class: "btn btn-primary" %>
<% end %>
```

#### Multiple File Upload

```erb
<%= form_with url: chat_ask_path(@chat), local: false, multipart: true do |f| %>
  <%= f.text_area :message, placeholder: "Message..." %>

  <!-- Multiple file selection -->
  <%= f.file_field :attachments, multiple: true,
                   accept: "image/*,video/*,audio/*,.pdf,.txt,.csv" %>

  <%= f.submit "Send" %>
<% end %>
```

## API Reference

### Chat Methods with Attachments

```ruby
# Single attachment
chat.ask(message, with: file_path_or_upload)

# Multiple attachments
chat.ask(message, with: [file1, file2, file3])

# With streaming
chat.ask(message, with: file) do |chunk|
  # Handle streaming chunk
end
```

### Message Attachment Methods

```ruby
message = chat.messages.last

# Access attachments
message.attachments.each do |attachment|
  puts attachment.filename
  puts attachment.content_type
  puts attachment.byte_size
end

# Extract content
content = message.extract_content

# Check if message has attachments
message.attachments.attached?
```

### File Type Support

| File Type | Extensions | Description |
|-----------|------------|-------------|
| Images | .jpg, .jpeg, .png, .gif, .webp | Visual analysis, OCR |
| Videos | .mp4, .mov, .webm, .avi | Video analysis, frame extraction |
| Audio | .mp3, .wav, .ogg, .m4a | Transcription, analysis |
| Documents | .pdf, .txt, .csv, .md | Text extraction, analysis |
| Code | .rb, .js, .py, .html, .css | Code review, analysis |

## Code Examples

### Controller with File Handling

```ruby
class ChatsController < ApplicationController
  def ask
    @chat = current_user.chats.find(params[:id])

    begin
      if params[:attachment].present?
        # Single file
        response = @chat.ask(params[:message], with: params[:attachment])
      elsif params[:attachments].present?
        # Multiple files
        response = @chat.ask(params[:message], with: params[:attachments])
      else
        # Text only
        response = @chat.ask(params[:message])
      end

      redirect_to @chat, notice: "Message sent successfully"
    rescue RubyLLM::Error => e
      redirect_to @chat, alert: "Error processing message: #{e.message}"
    end
  end

  private

  def chat_params
    params.permit(:message, :attachment, attachments: [])
  end
end
```

### Background Job for File Processing

```ruby
class ProcessAttachmentJob < ApplicationJob
  queue_as :default

  def perform(chat_id, message_content, attachment_ids)
    chat = Chat.find(chat_id)
    attachments = ActiveStorage::Attachment.where(id: attachment_ids)

    begin
      response = chat.ask(message_content, with: attachments) do |chunk|
        # Broadcast streaming updates
        ActionCable.server.broadcast(
          "chat_#{chat.id}",
          { type: 'chunk', content: chunk.content }
        )
      end

      # Broadcast completion
      ActionCable.server.broadcast(
        "chat_#{chat.id}",
        { type: 'complete', message_id: response.id }
      )
    rescue RubyLLM::Error => e
      ActionCable.server.broadcast(
        "chat_#{chat.id}",
        { type: 'error', message: e.message }
      )
    end
  end
end
```

### Service Object for Multi-Modal Processing

```ruby
class MultiModalChatService
  def initialize(chat, user_message, attachments = [])
    @chat = chat
    @user_message = user_message
    @attachments = Array(attachments)
  end

  def process
    validate_attachments!

    if @attachments.any?
      process_with_attachments
    else
      process_text_only
    end
  rescue RubyLLM::Error => e
    handle_error(e)
  end

  private

  def process_with_attachments
    response = @chat.ask(@user_message, with: @attachments) do |chunk|
      yield chunk if block_given?
    end

    extract_and_store_content(response)
    response
  end

  def process_text_only
    @chat.ask(@user_message)
  end

  def validate_attachments!
    @attachments.each do |attachment|
      unless supported_file_type?(attachment)
        raise "Unsupported file type: #{attachment.content_type}"
      end

      if attachment.byte_size > 50.megabytes
        raise "File too large: #{attachment.filename}"
      end
    end
  end

  def supported_file_type?(attachment)
    content_type = attachment.content_type
    [
      'image/', 'video/', 'audio/',
      'application/pdf', 'text/', 'application/json'
    ].any? { |type| content_type.start_with?(type) }
  end

  def extract_and_store_content(response)
    if response.attachments.any?
      extracted_content = response.extract_content
      # Store extracted content for search/indexing
      response.update(extracted_content: extracted_content)
    end
  end

  def handle_error(error)
    Rails.logger.error "Multi-modal processing error: #{error.message}"
    raise MultiModalError, error.message
  end
end
```

### Stimulus Controller for Drag & Drop

```javascript
// app/javascript/controllers/file_upload_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "preview", "dropZone"]

  connect() {
    this.bindDragAndDrop()
  }

  bindDragAndDrop() {
    ["dragenter", "dragover", "dragleave", "drop"].forEach(eventName => {
      this.dropZoneTarget.addEventListener(eventName, this.preventDefaults, false)
    })

    this.dropZoneTarget.addEventListener("drop", this.handleDrop.bind(this), false)
  }

  preventDefaults(e) {
    e.preventDefault()
    e.stopPropagation()
  }

  handleDrop(e) {
    const files = e.dataTransfer.files
    this.inputTarget.files = files
    this.updatePreview(files)
  }

  updatePreview(files) {
    this.previewTarget.innerHTML = ""

    Array.from(files).forEach(file => {
      const preview = document.createElement("div")
      preview.className = "file-preview"

      if (file.type.startsWith("image/")) {
        const img = document.createElement("img")
        img.src = URL.createObjectURL(file)
        img.style.maxWidth = "200px"
        preview.appendChild(img)
      } else {
        preview.textContent = `${file.name} (${this.formatFileSize(file.size)})`
      }

      this.previewTarget.appendChild(preview)
    })
  }

  formatFileSize(bytes) {
    if (bytes === 0) return "0 Bytes"
    const k = 1024
    const sizes = ["Bytes", "KB", "MB", "GB"]
    const i = Math.floor(Math.log(bytes) / Math.log(k))
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + " " + sizes[i]
  }
}
```

## Important Considerations

### File Size Limits
- Most providers have file size limits (typically 20-50MB)
- Consider implementing client-side compression for large files
- Use background jobs for processing large files

### Security
- Validate file types on both client and server
- Scan uploaded files for malware
- Implement proper access controls for file attachments
- Never trust file extensions alone - validate content type

### Performance
- Large files can significantly increase processing time
- Consider implementing progress indicators for file uploads
- Use streaming responses for better user experience
- Cache extracted content to avoid reprocessing

### Error Handling
```ruby
begin
  response = chat.ask(message, with: attachment)
rescue RubyLLM::FileTooLargeError => e
  # Handle file size exceeded
rescue RubyLLM::UnsupportedFileTypeError => e
  # Handle unsupported file type
rescue RubyLLM::FileProcessingError => e
  # Handle file processing failure
rescue RubyLLM::Error => e
  # Handle general RubyLLM errors
end
```

### Cost Considerations
- Files with visual content (images, videos) consume more tokens
- Large documents can result in high token usage
- Monitor token consumption for cost control
- Consider file compression or content summarization

## Related Documentation

- [Chat Basics](chat-basics.md) - Core chat functionality
- [Structured Output](structured-output.md) - JSON responses and schemas
- [Token Usage](token-usage.md) - Token tracking and cost management
- [RubyLLM Rails Guide](https://rubyllm.com/rails/) - Complete Rails integration
- [ActiveStorage Guide](https://guides.rubyonrails.org/active_storage_overview.html) - File attachment handling