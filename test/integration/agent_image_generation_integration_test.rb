require "test_helper"
require "support/vcr_setup"
require "base64"
require "net/http"
require "tempfile"

class AgentImageGenerationIntegrationTest < ActionDispatch::IntegrationTest

  OPENROUTER_IMAGES_URL = URI("https://openrouter.ai/api/v1/images")

  setup do
    @user = users(:confirmed_user)
    @account = @user.personal_account
    @agent = agents(:research_assistant)
    @agent.update_columns(account_id: @account.id) # seat a resident hosted in this room's account
    @chat = @account.chats.create!(
      model_id: "openrouter/auto",
      title: "Generated image integration",
      manual_responses: true,
      agent_ids: [ @agent.id ]
    )
    @agent_key = ApiKey.generate_for(@user, name: "Generated image integration", agent: @agent)
  end

  test "agent generates an image through OpenRouter and attaches it to a conversation" do
    generated = VCR.use_cassette(
      "agent_image_generation/openrouter_to_conversation",
      match_requests_on: [ :method, :uri, :body ]
    ) do
      generate_image
    end

    assert generated[:bytes].start_with?("\x89PNG".b, "\xFF\xD8\xFF".b, "RIFF".b),
      "Provider response should decode to a recognized image"

    Tempfile.create([ "agent-generated-image", generated[:extension] ]) do |file|
      file.binmode
      file.write(generated[:bytes])
      file.rewind

      upload = Rack::Test::UploadedFile.new(file.path, generated[:media_type], true, original_filename: "agent-generated#{generated[:extension]}")
      post api_v1_conversation_messages_url(@chat),
        params: {
          content: "A generated blue circle.",
          files: [ upload ]
        },
        headers: { "Authorization" => "Bearer #{@agent_key.raw_token}" }
    end

    assert_response :created
    message = @chat.messages.order(:created_at).last
    assert_equal "assistant", message.role
    assert_equal @agent, message.agent
    assert_equal "A generated blue circle.", message.content
    assert message.completed?
    assert_equal 1, message.attachments.count

    attachment = message.attachments.first
    assert_equal generated[:media_type], attachment.content_type
    assert_operator attachment.byte_size, :>, 100

    response_file = JSON.parse(response.body).dig("message", "files_json", 0)
    assert_equal attachment.filename.to_s, response_file["filename"]
    assert response_file["thumb_url"].present?
    assert response_file["preview_url"].present?

    transcript = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).send(:request_text)
    assert_includes transcript, "A generated blue circle."
    assert_includes transcript, attachment.filename.to_s
    assert_includes transcript, Rails.application.routes.url_helpers.api_v1_conversation_message_attachment_path(
      @chat,
      message,
      message.attachments_attachments.first
    )
  end

  private

  def generate_image
    request = Net::HTTP::Post.new(OPENROUTER_IMAGES_URL)
    request["Authorization"] = "Bearer #{openrouter_key}"
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/json"
    request.body = {
      model: "google/gemini-3.1-flash-lite-image",
      prompt: "A single small blue circle centered on a plain white background. No text.",
      resolution: "1K",
      aspect_ratio: "1:1",
      output_format: "png"
    }.to_json

    response = Net::HTTP.start(
      OPENROUTER_IMAGES_URL.host,
      OPENROUTER_IMAGES_URL.port,
      use_ssl: true,
      read_timeout: 120,
      open_timeout: 10
    ) { |http| http.request(request) }

    assert response.is_a?(Net::HTTPSuccess), "OpenRouter returned #{response.code}: #{response.body.to_s.first(500)}"
    payload = JSON.parse(response.body)
    image = payload.fetch("data").first
    media_type = image["media_type"].presence || "image/png"

    {
      bytes: Base64.strict_decode64(image.fetch("b64_json")),
      media_type: media_type,
      extension: extension_for(media_type)
    }
  end

  def openrouter_key
    @account.ai_api_key(:openrouter).presence || "vcr-replay-key"
  end

  def extension_for(media_type)
    {
      "image/jpeg" => ".jpg",
      "image/webp" => ".webp"
    }.fetch(media_type, ".png")
  end

end
