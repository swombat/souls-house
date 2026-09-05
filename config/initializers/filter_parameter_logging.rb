# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, /\Acode\z/i, :ssn, :cvv, :cvc
]

# SQL bind logging uses ActiveRecord::Base's application-wide inspection filter,
# not the graph model's filter. Exact names protect private graph fields (and the
# same fields elsewhere) without matching unrelated columns by substring.
Rails.application.config.filter_parameters += [
  /\A(?:content|description|source_uris|metadata|result|embedding|query|receipt)\z/
]
