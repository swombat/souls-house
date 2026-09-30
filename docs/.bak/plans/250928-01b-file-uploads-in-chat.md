# File Uploads in Chat - Implementation Specification (Revision B)

**Date:** 2025-09-28
**Status:** Ready for Implementation
**Complexity:** Medium
**Revision:** B (incorporates DHH feedback)

## Executive Summary

Add file upload functionality to the chat system, allowing users to attach images, audio, video, and documents to their messages. Files will be uploaded via Rails using ActiveStorage, validated in the model, and passed to RubyLLM for AI processing. The UI will support both drag-and-drop and button-based file selection, with consistent file display using icon + filename patterns.

## Overview

The chat system currently supports text-only conversations with AI models via RubyLLM. This specification adds multi-modal capabilities by enabling file attachments on user messages. The implementation leverages:

- **ActiveStorage** (already configured) for file management
- **RubyLLM's `with:` parameter** for passing files to AI models
- **Rails upload flow** (not direct S3) to keep complexity minimal
- **Existing real-time infrastructure** for broadcasting file attachments

## Key Design Decisions

### 1. Upload Strategy: Rails Server (Not Direct S3)
**Decision:** Upload via Rails server using standard ActiveStorage flow.

**Rationale:**
- ActiveStorage already configured with local storage (development) and ready for S3 (production)
- Simpler implementation with existing Rails patterns
- Easier to implement validation and security checks
- Direct S3 upload would require JavaScript libraries, signed URLs, and complex error handling
- Server uploads are acceptable for 50MB limit

### 2. File Storage: Local vs S3
**Decision:** Use local storage for development, S3 for production (via ActiveStorage configuration).

**Implementation:**
```ruby
# config/environments/production.rb
config.active_storage.service = :amazon

# config/storage.yml (uncomment and configure)
amazon:
  service: S3
  access_key_id: <%= Rails.application.credentials.dig(:aws, :access_key_id) %>
  secret_access_key: <%= Rails.application.credentials.dig(:aws, :secret_access_key) %>
  region: us-east-1
  bucket: helix-kit-production
```

### 3. File Lifecycle: Cascade Delete
**Decision:** Files are cascade-deleted when messages are deleted.

**Rationale:**
- The discard gem is not installed, and soft-delete adds unnecessary complexity
- ActiveStorage handles file deletion automatically via `dependent: :purge_later`
- Files are cascade-deleted when chats or messages are destroyed (Rails way)

## Database Schema

### No Migration Required

The Message model already has `has_many_attached :files` configured, and ActiveStorage tables exist. No database changes needed.

## Backend Implementation

### Step 1: Update MessagesController to Handle File Uploads

**File:** `/app/controllers/messages_controller.rb`

```ruby
class MessagesController < ApplicationController
  before_action :set_chat, except: :retry
  before_action :set_chat_for_retry, only: :retry

  def create
    @message = @chat.messages.build(message_params)
    @message.files.attach(params[:files]) if params[:files].present?

    if @message.save
      audit("create_message", @message, message_params.to_h)
      AiResponseJob.perform_later(@chat)
      redirect_to account_chat_path(@chat.account, @chat)
    else
      redirect_back_or_to account_chat_path(@chat.account, @chat),
        alert: "Failed to send message: #{@message.errors.full_messages.join(', ')}"
    end
  rescue StandardError => e
    error "Message creation failed: #{e.message}"
    redirect_back_or_to account_chat_path(@chat.account, @chat),
      alert: "Failed to send message: #{e.message}"
  end

  def retry
    AiResponseJob.perform_later(@chat)
    head :ok
  end

  private

  def set_chat
    @chat = current_account.chats.find(params[:chat_id])
  end

  def set_chat_for_retry
    @message = Message.find(params[:id])
    @chat = current_account.chats.find(@message.chat_id)
  end

  def message_params
    params.require(:message).permit(:content, :model_id)
  end
end
```

**Key Changes:**
1. Attach files BEFORE save (line 7) - allows validation to run
2. Remove all unnecessary `respond_to` blocks - Inertia handles format
3. Simple redirects on success/failure - trust your tools
4. Add `:model_id` to permitted params (line 42)

### Step 2: Add File Validation to Message Model

**File:** `/app/models/message.rb`

```ruby
class Message < ApplicationRecord
  include Broadcastable
  include ObfuscatesId
  include JsonAttributes
  include SyncAuthorizable

  acts_as_message

  belongs_to :chat, touch: true
  belongs_to :user, optional: true
  has_one :account, through: :chat

  has_many_attached :files

  broadcasts_to :chat

  validates :role, inclusion: { in: %w[user assistant system] }
  validates :content, presence: true, unless: -> { role == "assistant" }
  validate :acceptable_files

  scope :sorted, -> { order(created_at: :asc) }

  json_attributes :role, :content, :user_name, :user_avatar_url, :completed,
                  :created_at_formatted, :created_at_hour, :streaming, :files_json

  def files_json
    return [] unless files.attached?

    files.map do |file|
      {
        id: file.id,
        filename: file.filename.to_s,
        content_type: file.content_type,
        byte_size: file.byte_size,
        url: Rails.application.routes.url_helpers.url_for(file)
      }
    end
  end

  def file_paths_for_llm
    return [] unless files.attached?

    files.map do |file|
      if ActiveStorage::Blob.service.respond_to?(:path_for)
        ActiveStorage::Blob.service.path_for(file.key)
      else
        file.open { |f| f.path }
      end
    end
  end

  # ... existing methods remain unchanged ...

  private

  def acceptable_files
    return unless files.attached?

    files.each do |file|
      unless acceptable_file_type?(file)
        errors.add(:files, "#{file.filename}: file type not supported")
      end

      if file.byte_size > 50.megabytes
        errors.add(:files, "#{file.filename}: must be less than 50MB")
      end
    end
  end

  def acceptable_file_type?(file)
    acceptable_types = %w[
      image/png image/jpeg image/jpg image/gif image/webp image/bmp
      audio/mpeg audio/wav audio/m4a audio/ogg audio/flac
      video/mp4 video/quicktime video/x-msvideo video/webm
      application/pdf
      application/msword
      application/vnd.openxmlformats-officedocument.wordprocessingml.document
      text/plain text/markdown text/csv
    ]
    acceptable_types.include?(file.content_type)
  end
end
```

**Key Changes:**
1. Custom validation (not gem-based) - no external dependency
2. `files_json` uses `url_for(file)` - simpler and standard Rails way
3. `file_paths_for_llm` extracts file logic from job - proper separation of concerns
4. Duck typing for storage service - resilient to any backend

### Step 3: Update AiResponseJob to Pass Files to RubyLLM

**File:** `/app/jobs/ai_response_job.rb`

```ruby
class AiResponseJob < ApplicationJob
  STREAM_DEBOUNCE_INTERVAL = 0.2.seconds

  def perform(chat)
    @chat = chat
    @ai_message = nil
    @stream_buffer = +""
    @last_stream_flush_at = nil

    last_user_message = chat.messages.where(role: "user").last

    chat.on_new_message do
      @ai_message = chat.messages.order(:created_at).last
    end

    chat.on_end_message do |ruby_llm_message|
      finalize_message!(ruby_llm_message)
    end

    completion_options = {}
    if last_user_message&.files&.attached?
      completion_options[:with] = last_user_message.file_paths_for_llm
    end

    chat.complete(**completion_options) do |chunk|
      next unless chunk.content && @ai_message
      enqueue_stream_chunk(chunk.content)
    end
  rescue RubyLLM::ModelNotFoundError => e
    @model_not_found_error = true
    error "Model not found: #{e.message}, trying again..."
    RubyLLM.models.refresh!
    retry_job unless @model_not_found_error
  ensure
    flush_stream_buffer(force: true)
    @ai_message&.stop_streaming if @ai_message&.streaming?
  end

  # ... private methods remain unchanged ...
end
```

**Key Changes:**
1. Use `Message#file_paths_for_llm` - job doesn't know about storage
2. Cleaner logic - let the model handle complexity

### Step 4: Update ChatsController to Prevent N+1 Queries

**File:** `/app/controllers/chats_controller.rb`

```ruby
def show
  @chat = current_account.chats.includes(:messages).find(params[:id])
  @messages = @chat.messages.includes(files_attachments: :blob).sorted

  render inertia: "chats/show", props: {
    chat: @chat.to_inertia_props,
    messages: @messages.map(&:to_inertia_props),
    models: RubyLLM.models.list,
    account: current_account.to_inertia_props
  }
end
```

**Key Changes:**
1. Add `includes(files_attachments: :blob)` - prevents N+1 queries when loading files
2. Eager load attachments and blobs for efficient rendering

### Step 5: Routes

**File:** `/config/routes.rb`

No additional routes needed. ActiveStorage already provides file download routes via `url_for(file)`.

## Frontend Implementation

### Step 1: Create FileAttachment Component

**File:** `/app/frontend/lib/components/chat/FileAttachment.svelte`

```svelte
<script>
  import { File, FileImage, FileAudio, FileVideo, FilePdf, FileDoc } from 'phosphor-svelte';

  let { file } = $props();

  function getIcon(contentType) {
    if (!contentType) return File;

    if (contentType.startsWith('image/')) return FileImage;
    if (contentType.startsWith('audio/')) return FileAudio;
    if (contentType.startsWith('video/')) return FileVideo;
    if (contentType.includes('pdf')) return FilePdf;
    if (contentType.includes('word') || contentType.includes('document')) return FileDoc;

    return File;
  }

  function formatFileSize(bytes) {
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  }

  const IconComponent = getIcon(file.content_type);
</script>

<a
  href={file.url}
  download={file.filename}
  class="flex items-center gap-2 p-2 rounded-md border border-border bg-muted/50 hover:bg-muted transition-colors max-w-xs group"
>
  <svelte:component this={IconComponent} size={20} class="text-muted-foreground flex-shrink-0" />
  <div class="flex-1 min-w-0">
    <div class="text-sm font-medium truncate group-hover:text-primary transition-colors">
      {file.filename}
    </div>
    <div class="text-xs text-muted-foreground">
      {formatFileSize(file.byte_size)}
    </div>
  </div>
</a>
```

### Step 2: Create FileUploadInput Component

**File:** `/app/frontend/lib/components/chat/FileUploadInput.svelte`

```svelte
<script>
  import { Paperclip, X } from 'phosphor-svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';

  let {
    files = $bindable([]),
    disabled = false,
    maxFiles = 5,
    maxSize = 50 * 1024 * 1024
  } = $props();

  let fileInput;
  let error = $state(null);
  let dragActive = $state(false);

  const allowedTypes = [
    'image/png', 'image/jpeg', 'image/jpg', 'image/gif', 'image/webp', 'image/bmp',
    'audio/mpeg', 'audio/wav', 'audio/m4a', 'audio/ogg', 'audio/flac',
    'video/mp4', 'video/quicktime', 'video/x-msvideo', 'video/webm',
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'text/plain', 'text/markdown', 'text/csv'
  ];

  function validateFile(file) {
    if (!allowedTypes.includes(file.type)) {
      return 'File type not supported. Please upload images, audio, video, or documents.';
    }

    if (file.size > maxSize) {
      return `File too large. Maximum size is ${maxSize / (1024 * 1024)}MB.`;
    }

    return null;
  }

  function handleFileSelect(event) {
    const selectedFiles = Array.from(event.target.files || []);
    processFiles(selectedFiles);
  }

  function processFiles(selectedFiles) {
    error = null;

    if (files.length + selectedFiles.length > maxFiles) {
      error = `Maximum ${maxFiles} files allowed.`;
      return;
    }

    for (const file of selectedFiles) {
      const validationError = validateFile(file);
      if (validationError) {
        error = validationError;
        return;
      }
    }

    files = [...files, ...selectedFiles];
  }

  function removeFile(index) {
    files = files.filter((_, i) => i !== index);
    error = null;
  }

  function handleDragOver(event) {
    event.preventDefault();
    dragActive = true;
  }

  function handleDragLeave() {
    dragActive = false;
  }

  function handleDrop(event) {
    event.preventDefault();
    dragActive = false;

    const droppedFiles = Array.from(event.dataTransfer.files || []);
    processFiles(droppedFiles);
  }

  function formatFileSize(bytes) {
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  }
</script>

<div class="space-y-2">
  <input
    bind:this={fileInput}
    type="file"
    multiple
    accept=".png,.jpg,.jpeg,.gif,.webp,.bmp,.mp3,.wav,.m4a,.ogg,.flac,.mp4,.mov,.avi,.webm,.pdf,.doc,.docx,.txt,.md,.csv"
    onchange={handleFileSelect}
    {disabled}
    class="hidden"
  />

  <Button
    type="button"
    variant="ghost"
    size="sm"
    onclick={() => fileInput?.click()}
    {disabled}
    class="h-10 w-10 p-0"
    title="Attach files"
  >
    <Paperclip size={18} />
  </Button>

  {#if files.length > 0}
    <div class="space-y-2">
      {#each files as file, index}
        <div class="flex items-center gap-2 p-2 rounded-md border border-border bg-muted/50">
          <div class="flex-1 min-w-0">
            <div class="text-sm font-medium truncate">{file.name}</div>
            <div class="text-xs text-muted-foreground">{formatFileSize(file.size)}</div>
          </div>
          <Button
            type="button"
            variant="ghost"
            size="sm"
            onclick={() => removeFile(index)}
            {disabled}
            class="h-8 w-8 p-0"
          >
            <X size={16} />
          </Button>
        </div>
      {/each}
    </div>
  {/if}

  {#if error}
    <div class="text-sm text-destructive">{error}</div>
  {/if}
</div>
```

### Step 3: Update Chat Show Page

**File:** `/app/frontend/pages/chats/show.svelte`

Add file upload UI and display attachments in messages:

```svelte
<script>
  // ... existing imports ...
  import FileUploadInput from '$lib/components/chat/FileUploadInput.svelte';
  import FileAttachment from '$lib/components/chat/FileAttachment.svelte';

  // ... existing code ...

  let selectedFiles = $state([]);

  let messageForm = useForm({
    message: {
      content: '',
      model_id: selectedModel,
    }
  });

  function sendMessage() {
    logging.debug('messageForm:', $messageForm);
    $messageForm.message.model_id = selectedModel;

    if (!$messageForm.message.content.trim() && selectedFiles.length === 0) {
      logging.debug('Empty message and no files, returning');
      return;
    }

    const formData = new FormData();
    formData.append('message[content]', $messageForm.message.content);
    formData.append('message[model_id]', selectedModel);
    selectedFiles.forEach(file => formData.append('files[]', file));

    router.post(accountChatMessagesPath(account.id, chat.id), formData, {
      onSuccess: () => {
        logging.debug('Message sent successfully');
        $messageForm.message.content = '';
        selectedFiles = [];
      },
      onError: (errors) => {
        logging.error('Message send failed:', errors);
      },
    });
  }

  // ... existing code ...
</script>

<!-- ... existing template ... -->

<!-- Update message display to show files -->
{#each messages as message, index (message.id)}
  <!-- ... existing timestamp logic ... -->

  <div class="space-y-1">
    {#if message.role === 'user'}
      <div class="flex justify-end">
        <div class="max-w-[70%]">
          <Card.Root class="bg-indigo-200">
            <Card.Content class="p-4">
              {#if message.files_json && message.files_json.length > 0}
                <div class="space-y-2 mb-3">
                  {#each message.files_json as file}
                    <FileAttachment {file} />
                  {/each}
                </div>
              {/if}

              <Streamdown
                content={message.content}
                parseIncompleteMarkdown
                baseTheme="shadcn"
                class="prose"
                animation={{
                  enabled: true,
                  type: 'fade',
                  tokenize: 'word',
                  duration: 300,
                  timingFunction: 'ease-out',
                  animateOnMount: false
                }}
              />
            </Card.Content>
          </Card.Root>
          <div class="text-xs text-muted-foreground text-right mt-1">
            <span class="group">
              <span class="hidden group-hover:inline-block">({formatDateTime(message.created_at, true)})</span> {formatTime(message.created_at)}
            </span>
          </div>
        </div>
      </div>
    {:else}
      <!-- ... existing assistant message code ... -->
    {/if}
  </div>
{/each}

<!-- Update message input area -->
<div class="border-t border-border bg-muted/30 p-4">
  <div class="flex gap-3 items-end">
    <FileUploadInput bind:files={selectedFiles} disabled={messageForm.processing} />

    <div class="flex-1">
      <textarea
        bind:value={$messageForm.message.content}
        onkeydown={handleKeydown}
        placeholder="Type your message..."
        disabled={messageForm.processing}
        class="w-full resize-none border border-input rounded-md px-3 py-2 text-sm bg-background
               focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent
               min-h-[40px] max-h-[120px]"
        rows="1"></textarea>
    </div>
    <Button
      on:click={sendMessage}
      disabled={(!$messageForm.message.content.trim() && selectedFiles.length === 0) || messageForm.processing}
      size="sm"
      class="h-10 w-10 p-0">
      <ArrowUp size={16} />
    </Button>
  </div>
</div>
```

## Security & Validation

### File Type Validation
Restrict uploads to safe file types:
- **Images:** PNG, JPG, GIF, WEBP, BMP
- **Audio:** MP3, WAV, M4A, OGG, FLAC
- **Video:** MP4, MOV, AVI, WEBM
- **Documents:** PDF, Word (DOC, DOCX), TXT, MD, CSV

### File Size Validation
- **Maximum:** 50MB per file
- **Multiple files:** Up to 5 files per message (frontend limit)

### Implementation Layers
1. **Frontend validation** - Immediate user feedback
2. **Model validation** - Server-side enforcement with custom Rails validations
3. **Content-Type verification** - Rails checks MIME types

### Authorization Through Associations
Files are automatically scoped through associations:
- Files → Messages → Chats → Accounts
- ActiveStorage blob routes are public, but without knowing the signed ID, files are effectively private
- The existing `@chat = current_account.chats.find(params[:chat_id])` ensures proper scoping

## Testing Strategy

### Model Tests

**File:** `/test/models/message_test.rb`

```ruby
require "test_helper"

class MessageTest < ActiveSupport::TestCase
  test "should accept valid image file" do
    message = messages(:one)
    file = fixture_file_upload('test_image.png', 'image/png')
    message.files.attach(file)
    assert message.valid?
  end

  test "should reject file over 50MB" do
    message = messages(:one)
    large_blob = ActiveStorage::Blob.create!(
      key: SecureRandom.uuid,
      filename: "large.png",
      content_type: "image/png",
      byte_size: 51.megabytes,
      checksum: "abc123"
    )
    message.files.attach(large_blob)
    assert_not message.valid?
    assert_includes message.errors.full_messages.join, "50MB"
  end

  test "should reject invalid file type" do
    message = messages(:one)
    file = fixture_file_upload('test.exe', 'application/x-msdownload')
    message.files.attach(file)
    assert_not message.valid?
  end

  test "files_json returns correct structure" do
    message = messages(:one)
    file = fixture_file_upload('test_image.png', 'image/png')
    message.files.attach(file)

    json = message.files_json
    assert_equal 1, json.length
    assert_equal 'test_image.png', json.first[:filename]
    assert_equal 'image/png', json.first[:content_type]
    assert json.first[:url].present?
  end

  test "file_paths_for_llm returns correct paths" do
    message = messages(:one)
    file = fixture_file_upload('test_image.png', 'image/png')
    message.files.attach(file)

    paths = message.file_paths_for_llm
    assert_equal 1, paths.length
    assert paths.first.present?
  end
end
```

### Controller Tests

**File:** `/test/controllers/messages_controller_test.rb`

```ruby
require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:one)
    @chat = chats(:one)
    @user = users(:one)
    sign_in @user
  end

  test "should create message with file attachment" do
    file = fixture_file_upload('test_image.png', 'image/png')

    assert_difference('Message.count', 1) do
      assert_difference('ActiveStorage::Attachment.count', 1) do
        post account_chat_messages_path(@account, @chat), params: {
          message: { content: "Check this image", model_id: 1 },
          files: [file]
        }
      end
    end

    message = Message.last
    assert_equal 1, message.files.count
    assert_equal 'test_image.png', message.files.first.filename.to_s
  end

  test "should create message with multiple files" do
    file1 = fixture_file_upload('test_image.png', 'image/png')
    file2 = fixture_file_upload('test_document.pdf', 'application/pdf')

    assert_difference('Message.count', 1) do
      assert_difference('ActiveStorage::Attachment.count', 2) do
        post account_chat_messages_path(@account, @chat), params: {
          message: { content: "Multiple files", model_id: 1 },
          files: [file1, file2]
        }
      end
    end

    message = Message.last
    assert_equal 2, message.files.count
  end

  test "should create message without files" do
    assert_difference('Message.count', 1) do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "No files here", model_id: 1 }
      }
    end

    message = Message.last
    assert_equal 0, message.files.count
  end

  test "should reject invalid file type" do
    file = fixture_file_upload('test.exe', 'application/x-msdownload')

    assert_no_difference('Message.count') do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Malicious file", model_id: 1 },
        files: [file]
      }
    end
  end
end
```

### Integration Tests

**File:** `/test/integration/chat_file_upload_test.rb`

```ruby
require "test_helper"

class ChatFileUploadTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:one)
    @chat = chats(:one)
    @user = users(:one)
    sign_in @user
  end

  test "complete file upload and AI response flow" do
    file = fixture_file_upload('test_image.png', 'image/png')

    post account_chat_messages_path(@account, @chat), params: {
      message: { content: "What's in this image?", model_id: 1 },
      files: [file]
    }

    assert_redirected_to account_chat_path(@account, @chat)

    message = @chat.messages.order(:created_at).last
    assert_equal "What's in this image?", message.content
    assert_equal 1, message.files.count

    assert_enqueued_jobs 1, only: AiResponseJob
  end
end
```

## Implementation Checklist

- [ ] **Backend: Message Model**
  - [ ] Add custom file validation methods
  - [ ] Add `files_json` method
  - [ ] Add `file_paths_for_llm` method
  - [ ] Update `json_attributes` to include files

- [ ] **Backend: MessagesController**
  - [ ] Attach files BEFORE save
  - [ ] Add `:model_id` to permitted params
  - [ ] Simplify error handling (remove format blocks)

- [ ] **Backend: ChatsController**
  - [ ] Add `includes(files_attachments: :blob)` to prevent N+1

- [ ] **Backend: AiResponseJob**
  - [ ] Use `Message#file_paths_for_llm` method
  - [ ] Pass files via `with:` parameter

- [ ] **Frontend: Create Components**
  - [ ] Create FileAttachment.svelte component
  - [ ] Create FileUploadInput.svelte component

- [ ] **Frontend: Update Chat Show Page**
  - [ ] Add file upload button to message input
  - [ ] Update sendMessage to use FormData
  - [ ] Display files in user messages

- [ ] **Testing**
  - [ ] Write model tests for file validation
  - [ ] Write controller tests for file upload
  - [ ] Write integration test for complete flow
  - [ ] Create test fixtures (images, PDFs)

- [ ] **Production Setup**
  - [ ] Configure S3 bucket
  - [ ] Add AWS credentials to Rails credentials
  - [ ] Update production.rb to use :amazon service

## Edge Cases & Error Handling

### Frontend Errors
- **No file selected:** Button remains enabled, user can send text-only
- **Invalid file type:** Show error message, prevent upload
- **File too large:** Show error message with size limit
- **Too many files:** Show error message with file count limit
- **Network error:** Show generic error, allow retry

### Backend Errors
- **Validation failure:** Return 422 with error messages
- **Upload failure:** Log error, show user-friendly message
- **Missing file:** Treat as text-only message

### RubyLLM Integration Errors
- **Model doesn't support files:** RubyLLM handles gracefully
- **File download failure:** Log error, retry job

## Performance Considerations

### File Upload
- Server uploads are acceptable for 50MB limit
- No chunked upload needed

### File Storage
- Local storage for development (fast)
- S3 storage for production (scalable)

### Database
- Blob storage via ActiveStorage (efficient)
- N+1 prevention with proper includes
- File metadata indexed automatically

## Future Enhancements

1. **Image Thumbnails:** Generate thumbnails for image previews
2. **File Preview:** Show file content inline (images, PDFs)
3. **Progress Bar:** Upload progress for large files
4. **Direct S3 Upload:** Reduce server load for large files
5. **File Compression:** Compress images before upload
6. **Virus Scanning:** Scan files for malware
7. **File Expiration:** Auto-delete old files after N days

## Dependencies

### Required (Already Installed)
- ✅ ActiveStorage - File management
- ✅ ruby_llm - AI integration with file support

### Optional
- ❌ `active_storage_validations` - Not needed, using custom validations
- ❌ `discard` - Not needed, using cascade delete
- ❌ `aws-sdk-s3` - Installed by ActiveStorage when needed

### Frontend (Already Available)
- ✅ Inertia.js - Form handling with FormData
- ✅ Svelte 5 - Component framework
- ✅ phosphor-svelte - Icons

## Deployment Notes

### Development
```bash
# ActiveStorage uses local storage by default
# Files stored in storage/ directory
```

### Production
```ruby
# 1. Add S3 credentials
rails credentials:edit

# Add:
# aws:
#   access_key_id: YOUR_KEY
#   secret_access_key: YOUR_SECRET

# 2. Configure S3 bucket in config/storage.yml
amazon:
  service: S3
  access_key_id: <%= Rails.application.credentials.dig(:aws, :access_key_id) %>
  secret_access_key: <%= Rails.application.credentials.dig(:aws, :secret_access_key) %>
  region: us-east-1
  bucket: helix-kit-production

# 3. Update config/environments/production.rb
config.active_storage.service = :amazon
```

## Summary

This specification provides a complete implementation plan for adding file uploads to the chat system. The approach prioritizes simplicity and maintainability by:

1. Using standard Rails patterns (ActiveStorage, FormData uploads)
2. Attaching files BEFORE save to allow validation
3. Custom validations (no gem dependencies)
4. Proper separation of concerns (file logic in model, not job)
5. N+1 prevention with eager loading
6. Clean, simple controller with trust in Inertia
7. Comprehensive testing strategy

The implementation follows DHH's Rails-worthy standards:
- Fat models, skinny controllers
- Duck typing over string comparisons
- Trust your tools (Inertia, ActiveStorage)
- No unnecessary comments
- Code that feels effortless and obvious

Estimated implementation time: **1 day** for an experienced developer.