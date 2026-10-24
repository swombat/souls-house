require "openssl"

module RepositoryWatches
  # GitHub's X-Hub-Signature-256: "sha256=" + hex HMAC-SHA256 of the raw body
  # with the hook's secret. Compared in constant time.
  module Signature

    PREFIX = "sha256=".freeze

    module_function

    def valid?(secret:, body:, header:)
      return false if secret.blank? || header.blank?

      header = header.to_s
      return false unless header.start_with?(PREFIX)

      ActiveSupport::SecurityUtils.secure_compare(header, sign(secret, body))
    end

    def sign(secret, body)
      "#{PREFIX}#{OpenSSL::HMAC.hexdigest('SHA256', secret, body.to_s)}"
    end

  end
end
