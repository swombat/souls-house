require "test_helper"
require "support/app_oauth_test_helper"

# Issue #94 B, step 4c: attachments through /api/app/v1. Uploads go straight
# to storage with a URL the app token obtains for one conversation; the send
# names them and is checked again (ADR 0005: upload success is not post
# success). Downloads are a redirect under the same authority as the message.
class Api::App::V1::AttachmentsApiTest < ActionDispatch::IntegrationTest

  include AppOauthTestHelper
  include ActiveJob::TestHelper

  BYTES = "not really a png".b

  setup do
    @user = users(:existing_user)
    @account = accounts(:existing_user_account)
    @client = create_app_client
    @tokens = sign_in_device
    @chat = new_chat(@account, "Phone chat")
  end

  # --- uploads ---------------------------------------------------------------

  test "an upload is 201 with a signed id and a direct upload URL, and remembers who and where" do
    request_upload
    assert_response :created
    upload = response.parsed_body["upload"]
    blob = ActiveStorage::Blob.find_signed!(upload["id"])
    assert_equal "PUT", upload.dig("direct_upload", "method")
    assert upload.dig("direct_upload", "url").present?
    assert_equal "image/png", upload.dig("direct_upload", "headers", "Content-Type")
    assert_equal [ @user.id, @chat.id ], blob.metadata["app_upload"].values_at("user_id", "chat_id")
    refute blob.service.exist?(blob.key)
  end

  test "an upload is refused for bad declarations, a closed conversation, or one outside membership" do
    request_upload(checksum: "nope")
    assert_error :unprocessable_entity, "invalid_parameter"
    request_upload(byte_size: Message::Attachable::MAX_FILE_SIZE + 1)
    assert_error :unprocessable_entity, "invalid_parameter"
    request_upload(content_type: "not a type")
    assert_error :unprocessable_entity, "invalid_parameter"

    @chat.update!(archived_at: Time.current)
    request_upload
    assert_error :unprocessable_entity, "conversation_not_respondable"

    theirs = new_chat(accounts(:regular_user_account), "Theirs")
    request_upload(chat: theirs)
    assert_error :not_found, "not_found"
    assert_equal 0, ActiveStorage::Blob.count
  end

  # --- sending ---------------------------------------------------------------

  test "a send names finished uploads; they attach in order and download through the API" do
    first = uploaded_blob(filename: "a.png")
    second = uploaded_blob(filename: "b.png")

    send_message("key-00000001", "two pictures", [ first.signed_id, second.signed_id ])
    assert_response :created
    body = response.parsed_body["message"]
    message = @chat.messages.find(body["id"])
    assert_equal [ "a.png", "b.png" ], message.attachments.map { |a| a.filename.to_s }
    assert_equal [ "a.png", "b.png" ], body["attachments"].map { |a| a["filename"] }
    assert message.submission_digest.start_with?("v2:")

    get body["attachments"].first["download_path"], headers: bearer(@tokens)
    assert_response :redirect
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal first, blob_behind(response.location)
  end

  test "a file with no caption is a message" do
    send_message("key-00000001", nil, [ uploaded_blob.signed_id ])
    assert_response :created
    assert_equal 1, @chat.messages.find(response.parsed_body.dig("message", "id")).attachments.count
  end

  test "a text-only send still digests as v1, so earlier stored digests keep matching" do
    send_message("key-00000001", "just words")
    assert @chat.messages.last.submission_digest.start_with?("v1:")
  end

  test "a send before its upload has finished is a retryable 422 and saves nothing" do
    blob = declared_blob
    assert_no_difference -> { Message.count } do
      send_message("key-00000001", "too soon", [ blob.signed_id ])
    end
    assert_error :unprocessable_entity, "upload_incomplete"
    assert response.parsed_body.dig("error", "details", "retryable")

    blob.service.upload(blob.key, StringIO.new(BYTES), checksum: blob.checksum)
    send_message("key-00000001", "too soon", [ blob.signed_id ])
    assert_response :created
  end

  test "an upload made for another conversation, by another user, or already sent is refused" do
    other_chat = new_chat(@account, "Other")
    for_other_chat = uploaded_blob(chat: other_chat)
    by_other_user = uploaded_blob(user: users(:regular_user))
    not_via_app = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(BYTES), filename: "web.png")

    [ for_other_chat, by_other_user, not_via_app ].each_with_index do |blob, i|
      assert_no_difference -> { Message.count } do
        send_message("key-0000000#{i}", "hi #{i}", [ blob.signed_id ])
      end
      assert_error :unprocessable_entity, "invalid_attachment"
    end

    send_message("key-00000001", "hi", [ "forged--signed-id" ])
    assert_error :unprocessable_entity, "invalid_attachment"

    reused = uploaded_blob
    send_message("key-00000010", "first", [ reused.signed_id ])
    assert_response :created
    send_message("key-00000011", "second", [ reused.signed_id ])
    assert_error :unprocessable_entity, "invalid_attachment"
  end

  test "attachment_ids must be a short list of strings" do
    send_message("key-00000001", "hi", [])
    assert_error :unprocessable_entity, "invalid_parameter"
    send_message("key-00000001", "hi", Array.new(11) { "x" })
    assert_error :unprocessable_entity, "invalid_parameter"
  end

  # --- retries ---------------------------------------------------------------

  test "an identical retry is 200 and attaches nothing new; a re-upload of the same file also matches" do
    blob = uploaded_blob
    send_message("key-00000001", "pic", [ blob.signed_id ])
    first = response.parsed_body["message"]

    assert_no_difference -> { ActiveStorage::Attachment.count } do
      send_message("key-00000001", "pic", [ blob.signed_id ])
      assert_response :ok
      assert_equal first, response.parsed_body["message"]

      send_message("key-00000001", "pic", [ uploaded_blob.signed_id ])
      assert_response :ok
    end
  end

  test "a retry naming a different file, no file, or an unresolvable one is 409" do
    send_message("key-00000001", "pic", [ uploaded_blob.signed_id ])

    send_message("key-00000001", "pic", [ uploaded_blob(bytes: "other bytes").signed_id ])
    assert_error :conflict, "idempotency_conflict"
    send_message("key-00000001", "pic")
    assert_error :conflict, "idempotency_conflict"
    send_message("key-00000001", "pic", [ "forged--signed-id" ])
    assert_error :conflict, "idempotency_conflict"
  end

  # --- downloads -------------------------------------------------------------

  test "a download is 404 once the message is discarded, for another message's path, or outside membership" do
    team = accounts(:team_account)
    team_chat = new_chat(team, "Team")
    send_message("key-00000001", "pic", [ uploaded_blob(chat: team_chat).signed_id ], chat: team_chat)
    assert_response :created
    message = team_chat.messages.find(response.parsed_body.dig("message", "id"))
    attachment = message.attachments_attachments.first
    path = "/api/app/v1/conversations/#{team_chat.to_param}/messages/#{message.to_param}/attachments/#{attachment.id}"

    get path, headers: bearer(@tokens)
    assert_response :redirect

    other = team_chat.messages.create!(role: "user", user: @user, content: "no files")
    get "/api/app/v1/conversations/#{team_chat.to_param}/messages/#{other.to_param}/attachments/#{attachment.id}", headers: bearer(@tokens)
    assert_error :not_found, "not_found"

    message.discard_as_author!
    get path, headers: bearer(@tokens)
    assert_error :not_found, "not_found"

    send_message("key-00000002", "pic", [ uploaded_blob(chat: team_chat).signed_id ], chat: team_chat)
    kept = team_chat.messages.find(response.parsed_body.dig("message", "id"))
    kept_path = response.parsed_body.dig("message", "attachments", 0, "download_path")
    get kept_path, headers: bearer(@tokens)
    assert_response :redirect

    memberships(:team_member).destroy!
    get kept_path, headers: bearer(@tokens)
    assert_error :not_found, "not_found"
    assert kept.reload.attachments.attached?
  end

  # Review of 4c (Mira, PR #97): these three were her witnesses.
  test "an identical retry still matches after ActiveStorage re-identifies the file's type" do
    bytes = "%PDF-1.4\nminimal PDF bytes\n"
    blob = declared_blob(filename: "document.bin", bytes: bytes)
    blob.update!(content_type: "application/octet-stream")
    blob.service.upload(blob.key, StringIO.new(bytes), checksum: blob.checksum)
    send_message("retype-key-0001", "document", [ blob.signed_id ])
    assert_response :created
    assert_equal "application/pdf", blob.reload.content_type

    send_message("retype-key-0001", "document", [ blob.signed_id ])
    assert_response :ok
  end

  test "attachments keep submission order on reload, in history and changes" do
    older = uploaded_blob(filename: "older.png")
    newer = uploaded_blob(filename: "newer.png")
    send_message("order-key-0001", "reverse upload order", [ newer.signed_id, older.signed_id ])
    assert_response :created
    expected = [ "newer.png", "older.png" ]
    assert_equal expected, response.parsed_body.dig("message", "attachments").map { |a| a["filename"] }

    get "/api/app/v1/conversations/#{@chat.to_param}/messages", headers: bearer(@tokens)
    assert_equal expected, response.parsed_body["messages"].last["attachments"].map { |a| a["filename"] }

    get "/api/app/v1/conversations/#{@chat.to_param}/changes", params: { since: 0 }, headers: bearer(@tokens)
    changed = response.parsed_body["changes"].find { |m| m["attachments"].present? }
    assert_equal expected, changed["attachments"].map { |a| a["filename"] }

    send_message("order-key-0001", "reverse upload order", [ newer.signed_id, older.signed_id ])
    assert_response :ok
    assert_equal expected, response.parsed_body.dig("message", "attachments").map { |a| a["filename"] }
  end

  test "an upload claimed by an interleaved send is refused, and only one message holds it" do
    blob = uploaded_blob
    service = blob.service
    original = service.method(:exist?)
    interleaved = false
    service.stub(:exist?, lambda { |key|
      unless interleaved
        interleaved = true
        winner = Messages::PostFromHuman.new(chat: @chat, user: @user, content: "winner", files: [ blob ], client_message_id: "claim-winner-01").call
        assert winner.created?
      end
      original.call(key)
    }) do
      assert_difference("Message.count", 1) do # the interleaved send only
        send_message("claim-loser-001", "loser", [ blob.signed_id ])
      end
    end
    assert_error :unprocessable_entity, "invalid_attachment"
    assert_equal 1, blob.attachments.count
  end

  test "the same send interleaved with itself answers with the recorded acceptance" do
    blob = uploaded_blob
    service = blob.service
    original = service.method(:exist?)
    winner = nil
    service.stub(:exist?, lambda { |key|
      winner ||= Messages::PostFromHuman.new(chat: @chat, user: @user, content: "twin", files: [ ActiveStorage::Blob.find(blob.id) ], client_message_id: "claim-twin-0001").call
      original.call(key)
    }) do
      assert_difference("Message.count", 1) do # the interleaved send only
        send_message("claim-twin-0001", "twin", [ blob.signed_id ])
      end
    end
    assert_response :ok
    assert_equal winner.message.to_param, response.parsed_body.dig("message", "id")
    assert_equal 1, blob.attachments.count
  end

  private

  # The disk service's URL carries the blob key in a signed token.
  def blob_behind(url)
    token = URI(url).path.split("/")[-2]
    ActiveStorage::Blob.find_by!(key: ActiveStorage.verifier.verified(token, purpose: :blob_key).with_indifferent_access[:key])
  end

  def new_chat(account, title)
    agent = account.agents.create!(name: "Grok #{SecureRandom.hex(3)}", system_prompt: "Test", runtime: "external")
    account.chats.new(model_id: "openrouter/auto", title: title, manual_responses: true).tap do |chat|
      chat.agent_ids = [ agent.id ]
      chat.save!
    end
  end

  def checksum(bytes = BYTES) = Digest::MD5.base64digest(bytes)

  def request_upload(chat: @chat, filename: "photo.png", content_type: "image/png", byte_size: BYTES.bytesize, checksum: checksum())
    post "/api/app/v1/conversations/#{chat.to_param}/uploads",
         params: { filename: filename, content_type: content_type, byte_size: byte_size, checksum: checksum },
         headers: bearer(@tokens), as: :json
  end

  def declared_blob(chat: @chat, user: @user, filename: "photo.png", bytes: BYTES)
    ActiveStorage::Blob.create_before_direct_upload!(
      filename: filename, byte_size: bytes.bytesize, checksum: checksum(bytes), content_type: "image/png",
      metadata: { "app_upload" => { "user_id" => user.id, "chat_id" => chat.id } }
    )
  end

  # What a finished direct upload leaves behind.
  def uploaded_blob(bytes: BYTES, **options)
    declared_blob(bytes: bytes, **options).tap do |blob|
      blob.service.upload(blob.key, StringIO.new(bytes), checksum: blob.checksum)
    end
  end

  def send_message(client_message_id, content, attachment_ids = nil, chat: @chat)
    params = { client_message_id: client_message_id }
    params[:content] = content unless content.nil?
    params[:attachment_ids] = attachment_ids unless attachment_ids.nil?
    post "/api/app/v1/conversations/#{chat.to_param}/messages", params: params, headers: bearer(@tokens), as: :json
  end

  def assert_error(status, code)
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
    assert response.parsed_body.dig("error", "request_id").present?
  end

end
