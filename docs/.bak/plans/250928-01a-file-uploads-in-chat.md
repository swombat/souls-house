# File Uploads in Chat - Implementation Specification

**Date:** 2025-09-28
**Status:** Ready for Implementation
**Complexity:** Medium

## Executive Summary

Add file upload functionality to the chat system, allowing users to attach images, audio, video, and documents to their messages. Files will be uploaded via Rails (not direct S3), validated and stored using ActiveStorage, and passed to RubyLLM for AI processing. The UI will support both drag-and-drop and button-based file selection, with consistent file display using icon + filename patterns.

## Overview

The chat system currently supports text-only conversations with AI models via RubyLLM. This specification adds multi-modal capabilities by enabling file attachments on user messages. The implementation leverages:

- **ActiveStorage** (already configured) for file management
- **RubyLLM's `with:` parameter** for passing files to AI models
- **Rails upload flow** (not direct S3) to keep complexity minimal
- **Existing real-time infrastructure** for broadcasting file attachments

## Key Design Decisions

### 1. Upload Strategy: Rails Server vs Direct S3
**Decision:** Upload via Rails server using standard ActiveStorage flow.

**Rationale:**
- ActiveStorage already configured with local storage (development) and ready for S3 (production)
- Simpler implementation with existing Rails patterns
- No need for pre-signed URLs or client-side S3 libraries
- Easier to implement validation and security checks
- Direct S3 upload would require JavaScript libraries, signed URLs, and more complex error handling

**Trade-offs:**
- Server uploads use more memory (acceptable for 50MB limit)
- Slightly higher latency (negligible for typical files)
- **Benefit:** Significantly simpler, more maintainable code

### 2. File Storage: Local vs S3
**Decision:** Use local storage for development, S3 for production (via ActiveStorage configuration).

**Implementation:**
```ruby
# config/environments/production.rb
config.active_storage.service = :amazon  # Change from :local to :amazon

# config/storage.yml (uncomment and configure)
amazon:
  service: S3
  access_key_id: <%= Rails.application.credentials.dig(:aws, :access_key_id) %>
  secret_access_key: <%= Rails.application.credentials.dig(:aws, :secret_access_key) %>
  region: us-east-1
  bucket: helix-kit-production
```

### 3. File Lifecycle: Soft Delete
**Decision:** Files are NOT soft-deleted when messages are deleted (simpler approach).

**Rationale:**
- The requirements document mentions soft-delete with discard gem, but discard is not installed
- ActiveStorage handles file deletion automatically via `dependent: :purge_later`
- Simpler to implement without adding new gem dependency
- Files are cascade-deleted when chats or messages are destroyed (Rails way)

**If soft-delete is truly required:**
- Add `gem "discard"` to Gemfile
- Implement soft-delete on Message model
- Override ActiveStorage deletion behavior

## Database Schema

### No Migration Required

The Message model already has `has_many_attached :files` configured, and ActiveStorage tables exist. No database changes needed.

**Verification:**
```ruby
# app/models/message.rb (line 14)
has_many_attached :files  # ✓ Already exists
```

## Backend Implementation

### Step 1: Update MessagesController to Handle File Uploads

**File:** `/app/controllers/messages_controller.rb`

```ruby
class MessagesController < ApplicationController
  before_action :set_chat, except: :retry
  before_action :set_chat_for_retry, only: :retry

  def create
    @message = @chat.messages.build(
      message_params.merge(user: Current.user, role: "user")
    )

    if @message.save
      # Attach files if present (supports multiple files)
      if params[:files].present?
        params[:files].each do |file|
          @message.files.attach(file)
        end
      end

      audit("create_message", @message, message_params.to_h)
      AiResponseJob.perform_later(@chat)

      respond_to do |format|
        format.html { redirect_to account_chat_path(@chat.account, @chat) }
        format.json { render json: @message, status: :created }
        format.any { redirect_to account_chat_path(@chat.account, @chat) }
      end
    else
      respond_to do |format|
        format.html { redirect_back_or_to account_chat_path(@chat.account, @chat), alert: "Failed to send message: #{@message.errors.full_messages.join(', ')}" }
        format.json { render json: { errors: @message.errors.full_messages }, status: :unprocessable_entity }
        format.any do
          if request.headers["X-Inertia"]
            redirect_back_or_to account_chat_path(@chat.account, @chat), alert: "Failed to send message: #{@message.errors.full_messages.join(', ')}"
          else
            render json: { errors: @message.errors.full_messages }, status: :unprocessable_entity
          end
        end
      end
    end
  rescue StandardError => e
    error "Message creation failed: #{e.message}"
    error e.backtrace.join("\n")

    respond_to do |format|
      format.html { redirect_back_or_to account_chat_path(@chat.account, @chat), alert: "Failed to send message: #{e.message}" }
      format.json { render json: { errors: [e.message] }, status: :unprocessable_entity }
      format.any do
        if request.headers["X-Inertia"]
          redirect_back_or_to account_chat_path(@chat.account, @chat), alert: "Failed to send message: #{e.message}"
        else
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end
      end
    end
  end

  # ... rest of controller ...
end
```

**Changes:**
- Line 13: Remove existing `@message.files.attach(params[:files])` (incorrect placement)
- Lines 16-20: Add proper file attachment after save with iteration for multiple files
- Keep existing error handling unchanged

### Step 2: Add File Validation to Message Model

**File:** `/app/models/message.rb`

```ruby
class Message < ApplicationRecord
  # ... existing code ...

  has_many_attached :files

  # Add file validations
  validates :files,
    content_type: {
      in: %w[
        image/png image/jpeg image/jpg image/gif image/webp image/bmp
        audio/mpeg audio/wav audio/m4a audio/ogg audio/flac
        video/mp4 video/quicktime video/x-msvideo video/webm
        application/pdf
        application/msword
        application/vnd.openxmlformats-officedocument.wordprocessingml.document
        text/plain text/markdown text/csv
      ],
      message: 'must be an image, audio, video, or document file'
    },
    size: {
      less_than: 50.megabytes,
      message: 'must be less than 50MB'
    },
    if: -> { files.attached? }

  # ... existing code ...

  # Add files_json for frontend
  def files_json
    return [] unless files.attached?

    files.map do |file|
      {
        id: file.id,
        filename: file.filename.to_s,
        content_type: file.content_type,
        byte_size: file.byte_size,
        url: Rails.application.routes.url_helpers.rails_blob_path(file, only_path: true)
      }
    end
  end

  # Update json_attributes to include files
  json_attributes :role, :content, :user_name, :user_avatar_url, :completed,
                  :created_at_formatted, :created_at_hour, :streaming, :files_json

  # ... existing code ...
end
```

**Changes:**
- Add `active_storage_validations` gem validations for file content type and size
- Add `files_json` method to serialize file attachments for Inertia
- Update `json_attributes` to include `files_json`

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

    # Get the last user message (which may have files)
    last_user_message = chat.messages.where(role: "user").order(created_at: :desc).first

    chat.on_new_message do
      @ai_message = chat.messages.order(:created_at).last
    end

    chat.on_end_message do |ruby_llm_message|
      finalize_message!(ruby_llm_message)
    end

    # Build RubyLLM options with files if present
    completion_options = {}

    if last_user_message&.files&.attached?
      # Get file paths for attached files
      file_paths = last_user_message.files.map do |file|
        # ActiveStorage uses Disk service in dev, which stores in storage/
        # For S3, we'll need to download temporarily
        if file.service_name == "local" || file.service_name == "test"
          ActiveStorage::Blob.service.path_for(file.key)
        else
          # For S3 and other services, download to tempfile
          tempfile = Tempfile.new([file.filename.base, file.filename.extension_with_delimiter])
          tempfile.binmode
          file.download { |chunk| tempfile.write(chunk) }
          tempfile.rewind
          tempfile.path
        end
      end

      # Pass files using RubyLLM's with: parameter
      completion_options[:with] = file_paths.length == 1 ? file_paths.first : file_paths
    end

    chat.complete(**completion_options) do |chunk|
      next unless chunk.content && @ai_message

      enqueue_stream_chunk(chunk.content)
    end
  rescue RubyLLM::ModelNotFoundError => e
    @model_not_found_error = true
    error "Model not found: #{e.message}, trying again..."
    RubyLLM.models.refresh!
    self.retry_job unless @model_not_found_error
  ensure
    flush_stream_buffer(force: true)
    @ai_message&.stop_streaming if @ai_message&.streaming?
  end

  # ... rest of job unchanged ...
end
```

**Changes:**
- Lines 10-11: Get last user message to check for files
- Lines 23-41: Build file paths array for RubyLLM
- Handle both local storage (direct path) and S3 (download to tempfile)
- Line 44: Pass files to RubyLLM via `with:` parameter

### Step 4: Add File Download Route

**File:** `/config/routes.rb`

```ruby
# Inside the resources :chats block
resources :chats do
  resources :messages, only: [:create] do
    member do
      post :retry
    end
  end

  # No additional route needed - ActiveStorage provides rails/active_storage/blobs/:id/*
  # Files are accessible via rails_blob_path(file)
end
```

**Note:** ActiveStorage already provides download routes. No additional route configuration needed.

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

**Purpose:** Reusable component to display file attachments with appropriate icons and download functionality.

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
    maxSize = 50 * 1024 * 1024 // 50MB
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
  <!-- File input (hidden) -->
  <input
    bind:this={fileInput}
    type="file"
    multiple
    accept=".png,.jpg,.jpeg,.gif,.webp,.bmp,.mp3,.wav,.m4a,.ogg,.flac,.mp4,.mov,.avi,.webm,.pdf,.doc,.docx,.txt,.md,.csv"
    onchange={handleFileSelect}
    {disabled}
    class="hidden"
  />

  <!-- Upload button -->
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

  <!-- Selected files list -->
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

  <!-- Error message -->
  {#if error}
    <div class="text-sm text-destructive">{error}</div>
  {/if}
</div>
```

**Purpose:** File upload component with drag-and-drop support, validation, and file preview.

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

  // Update the form initialization
  let messageForm = useForm({
    message: {
      content: '',
      model_id: selectedModel,
    },
    files: []  // Add files array
  });

  function sendMessage() {
    logging.debug('messageForm:', $messageForm);
    $messageForm.message.model_id = selectedModel;

    if (!$messageForm.message.content.trim() && selectedFiles.length === 0) {
      logging.debug('Empty message and no files, returning');
      return;
    }

    // Create FormData for file upload
    const formData = new FormData();
    formData.append('message[content]', $messageForm.message.content);
    formData.append('message[model_id]', selectedModel);

    // Append files
    selectedFiles.forEach((file) => {
      formData.append('files[]', file);
    });

    // Use router.post with FormData
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
              <!-- Show attached files -->
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
      <!-- Assistant messages don't have files -->
      <!-- ... existing assistant message code ... -->
    {/if}
  </div>
{/each}

<!-- Update message input area -->
<div class="border-t border-border bg-muted/30 p-4">
  <div class="flex gap-3 items-end">
    <!-- File upload button -->
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

**Changes:**
- Add `FileUploadInput` and `FileAttachment` components
- Update `sendMessage()` to use FormData for file uploads
- Display attached files in user messages
- Show file upload UI in message input area

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
2. **ActiveStorage validation** - Server-side enforcement via `active_storage_validations` gem
3. **Content-Type verification** - Rails checks MIME types

### Security Considerations
- ✅ All files stored via ActiveStorage (secure by default)
- ✅ File downloads require authentication (Rails session)
- ✅ No direct file path exposure (blob URLs only)
- ✅ Content-Type validation prevents executable uploads
- ✅ Size limits prevent DoS attacks
- ✅ Files scoped to messages → chats → accounts (authorization built-in)

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
    # Create a large blob
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
          message: { content: "Check this image" },
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
          message: { content: "Multiple files" },
          files: [file1, file2]
        }
      end
    end

    message = Message.last
    assert_equal 2, message.files.count
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

    # Upload file with message
    post account_chat_messages_path(@account, @chat), params: {
      message: { content: "What's in this image?" },
      files: [file]
    }

    assert_redirected_to account_chat_path(@account, @chat)

    # Verify message was created with file
    message = @chat.messages.order(:created_at).last
    assert_equal "What's in this image?", message.content
    assert_equal 1, message.files.count

    # Verify AI response job was enqueued
    assert_enqueued_jobs 1, only: AiResponseJob
  end
end
```

### System Tests (Optional - Playwright MCP)

Use Playwright MCP to test:
1. Click paperclip button → file picker opens
2. Select file → file appears in preview
3. Send message → file appears in message history
4. Click file → download triggers

## Implementation Checklist

- [ ] **Backend: Message Model**
  - [ ] Add file validations (content_type, size)
  - [ ] Add `files_json` method
  - [ ] Update `json_attributes` to include files

- [ ] **Backend: MessagesController**
  - [ ] Update `create` action to handle file uploads
  - [ ] Handle multiple file attachments
  - [ ] Maintain existing error handling

- [ ] **Backend: AiResponseJob**
  - [ ] Get last user message with files
  - [ ] Build file paths for RubyLLM
  - [ ] Handle local vs S3 storage
  - [ ] Pass files via `with:` parameter

- [ ] **Backend: ActiveStorage Configuration**
  - [ ] Verify storage.yml has S3 configuration ready
  - [ ] Update production.rb to use S3 (when deploying)
  - [ ] Add AWS credentials via Rails credentials

- [ ] **Frontend: Create Components**
  - [ ] Create FileAttachment.svelte component
  - [ ] Create FileUploadInput.svelte component
  - [ ] Install phosphor-svelte icons if not present

- [ ] **Frontend: Update Chat Show Page**
  - [ ] Add file upload button to message input
  - [ ] Update sendMessage to use FormData
  - [ ] Display files in user messages
  - [ ] Handle file removal before sending

- [ ] **Testing**
  - [ ] Write model tests for file validation
  - [ ] Write controller tests for file upload
  - [ ] Write integration test for complete flow
  - [ ] Create test fixtures (images, PDFs)
  - [ ] Test with Playwright MCP

- [ ] **Production Setup**
  - [ ] Configure S3 bucket
  - [ ] Add AWS credentials to Rails credentials
  - [ ] Update production.rb to use :amazon service
  - [ ] Test file uploads in staging

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
- **S3 unavailable:** Fall back to error state, don't crash job

### RubyLLM Integration Errors
- **Model doesn't support files:** RubyLLM will handle gracefully
- **File download failure:** Log error, retry job
- **Tempfile cleanup:** Ensure tempfiles are deleted after job

## Performance Considerations

### File Upload
- **Direct upload:** Not implemented (keep it simple)
- **Chunked upload:** Not needed for 50MB limit
- **Progress indicator:** Consider adding for large files

### File Storage
- **Local storage:** Fast but not scalable
- **S3 storage:** Slower uploads but production-ready
- **CDN:** Consider CloudFront for file downloads (future)

### Database
- **Blob storage:** ActiveStorage stores blobs efficiently
- **Attachment count:** No N+1 queries with proper includes
- **File metadata:** Indexed by ActiveStorage automatically

## Future Enhancements

1. **Image Thumbnails:** Generate thumbnails for image previews
2. **File Preview:** Show file content inline (images, PDFs)
3. **Progress Bar:** Upload progress for large files
4. **Direct S3 Upload:** Reduce server load for large files
5. **File Compression:** Compress images before upload
6. **Virus Scanning:** Scan files for malware (ClamAV)
7. **File Expiration:** Auto-delete old files after N days
8. **Download Analytics:** Track file download counts

## Dependencies

### Required (Already Installed)
- ✅ `active_storage_validations` - File validation
- ✅ `image_processing` - Image manipulation (optional)
- ✅ `ruby_llm` - AI integration with file support

### Optional (Not Required)
- ❌ `discard` - Soft delete (not needed, use ActiveRecord cascade delete)
- ❌ `aws-sdk-s3` - Installed by ActiveStorage when needed

### Frontend (Already Available)
- ✅ Inertia.js - Form handling with FormData
- ✅ Svelte 5 - Component framework
- ✅ phosphor-svelte - Icons (or use existing icon library)

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

### Docker/Kamal
```yaml
# Ensure AWS credentials are available as environment variables
# or mounted via Rails credentials
```

## Summary

This specification provides a complete implementation plan for adding file uploads to the chat system. The approach prioritizes simplicity and maintainability by:

1. Using standard Rails patterns (ActiveStorage, FormData uploads)
2. Leveraging existing infrastructure (Inertia, Svelte, real-time sync)
3. Following established code conventions (concerns, validations, component structure)
4. Implementing comprehensive validation and security measures
5. Providing clear testing strategy and edge case handling

The implementation should take approximately **1-2 days** for an experienced developer, with most complexity in frontend file handling and RubyLLM integration.