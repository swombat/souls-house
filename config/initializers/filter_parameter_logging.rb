# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :ticket, :code_verifier, :_key, :crypt, :salt, :certificate, :otp, /\Acode\z/i, :ssn, :cvv, :cvc,
  :activity, :events, /\Anote\z/, :rr_ms, :observed_at, :HTTP_AUTHORIZATION, :HTTP_SEC_WEBSOCKET_PROTOCOL
]

# SQL bind logging uses ActiveRecord::Base's application-wide inspection filter,
# not the graph model's filter. Exact names protect private graph fields (and the
# same fields elsewhere) without matching unrelated columns by substring.
Rails.application.config.filter_parameters += [
  /\A(?:content|description|source_uris|metadata|result|embedding|query|receipt)\z/
]

# Inference bodies contain private resident conversations and tool definitions.
Rails.application.config.filter_parameters += [ /\A(?:messages|tools|reasoning|tool_choice|response_format)\z/ ]

# A saved rhythm invitation can contain the same private prose as a message.
Rails.application.config.filter_parameters += [ /\Aopening\z/ ]

# Voice prints are biometric data (Field recordings, spec §9): never logged.
Rails.application.config.filter_parameters += [ /\A(?:print|voiceprints?)\z/ ]
