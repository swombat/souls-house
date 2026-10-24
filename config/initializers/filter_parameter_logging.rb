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

# Model provider keys reach the API as <provider>_api_key (masked by :_key).
# The draft API's `set: { provider: key }` shape is refused, but a client still
# sending it would otherwise have its keys logged before the refusal.
Rails.application.config.filter_parameters += [ /\Aset\z/ ]

# Pasted service credentials (POST service_connections, web and API) travel as
# credentials[<field>]. Field names like api_key and secret_key are already
# masked; this masks every field, whatever a provider calls it.
Rails.application.config.filter_parameters += [ /\Acredentials\z/ ]

# Comms connector events carry Daniel's WhatsApp messages, contacts and the
# pairing QR. `messages` and `code` are already filtered above; `chats`
# covers chat names, and the exact field names cover any other nesting.
Rails.application.config.filter_parameters += [
  /\A(?:chats|body|caption|sender_name|sender_id|qr|pairing_qr)\z/, /\Achats\.name\z/
]

# A connector's status.changed event names the paired account: its phone
# number and display name (`identity`), which land in the connection's
# external_subject_id and external_identity. The connector end-to-end test's
# log check found both in the request parameters and the SQL binds.
Rails.application.config.filter_parameters += [ /\A(?:identity|external_identity|external_subject_id)\z/ ]

# A Telegram phone sign-in posts the account's phone number (`phone`) and
# the code Telegram sent (`code`, already masked above) to
# Accounts::ServiceConnectionLoginsController, which forwards both to the
# connector and keeps neither.
Rails.application.config.filter_parameters += [ /\Aphone\z/ ]

# WhatsApp's phone number pairing: the owner posts `phone` (above) to
# Accounts::ServiceConnectionPairingsController#phone, which forwards it to
# the connector as `phone_number` (never logged either way); the code the
# connector sends back is `code` (masked above) and is stored encrypted in
# `pairing_phone_code`, masked here in SQL binds too.
Rails.application.config.filter_parameters += [ /\A(?:phone_number|pairing_phone_code)\z/ ]

# Companion device credentials and temporary file bodies never enter logs.
Rails.application.config.filter_parameters += [
  /\A(?:device_credential|credential_digest|previous_credential_digest|body_base64|argv|stdin|stdin_base64)\z/
]

# A transcription webhook carries the whole transcript: its text and every
# timed word (about 1.6 MB for a 50-minute meeting). Logged in full, eight
# arriving together pushed everything else out of the web container's 10 MB
# log (2026-10-20), and a transcript is as private as a message.
Rails.application.config.filter_parameters += [ /\A(?:words|text)\z/ ]
