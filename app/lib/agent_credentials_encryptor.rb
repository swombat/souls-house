class AgentCredentialsEncryptor

  def initialize(agent, master_key_b64, outbound_token:, github_deploy_key: nil, provider_keys: nil)
    require "base64"

    @agent = agent
    @outbound_token = outbound_token
    @github_deploy_key = github_deploy_key
    @provider_keys = provider_keys
    @master_key = Base64.strict_decode64(master_key_b64)
    raise ArgumentError, "master key must be 32 bytes" unless @master_key.bytesize == 32
  end

  def encrypt
    require "openssl"
    require "yaml"

    plaintext = plaintext_yaml
    cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
    cipher.key = master_key
    nonce = SecureRandom.bytes(12)
    cipher.iv = nonce
    ciphertext = cipher.update(plaintext) + cipher.final
    tag = cipher.auth_tag

    <<~YAML
      # credentials.yml.enc - encrypted with your master key. Do not edit by hand.
      # Generated #{Time.current.utc.iso8601} by HelixKit.
      algorithm: aes-256-gcm
      nonce: #{Base64.strict_encode64(nonce)}
      ciphertext: #{Base64.strict_encode64(ciphertext + tag)}
      helix_kit_signature: #{signature_for(plaintext)}
    YAML
  end

  private

  attr_reader :agent, :master_key, :outbound_token, :github_deploy_key, :provider_keys

  def plaintext_yaml
    credentials = {
      "agent_id" => agent_slug,
      "agent_uuid" => agent.uuid,
      "helix_kit" => {
        "app_url" => helix_kit_app_url,
        "bearer_token" => outbound_token
      },
      "trigger" => {
        "bearer_token" => agent.trigger_bearer_token
      }
    }

    if github_deploy_key.present?
      credentials["github"] = {
        "deploy_key" => github_deploy_key
      }
    end

    llm_provider_keys = provider_keys || agent.account.ai_provider_keys
    if llm_provider_keys["GEMINI_API_KEY"].present?
      llm_provider_keys = llm_provider_keys.merge("GOOGLE_API_KEY" => llm_provider_keys["GEMINI_API_KEY"])
    end
    credentials["llm_provider_keys"] = llm_provider_keys if llm_provider_keys.present?

    credentials.to_yaml
  end

  def agent_slug
    agent.name.to_s.parameterize.presence || "agent-#{agent.id}"
  end

  def helix_kit_app_url
    configured_url(:helix_kit_app_url) ||
      Rails.application.credentials.dig(:app, :url) ||
      ENV["SOULSHOUSE_APP_URL"] ||
      "http://localhost:#{LocalInstance.current.web_port}/"
  end

  def configured_url(name)
    config = Rails.application.config.x.to_h
    return unless config.key?(name)

    config[name].presence
  end

  def signature_for(plaintext)
    OpenSSL::HMAC.hexdigest("SHA256", signing_key, plaintext)
  end

  def signing_key
    Rails.application.credentials.dig(:agent_credentials_signing_key) ||
      Rails.application.secret_key_base
  end

end
