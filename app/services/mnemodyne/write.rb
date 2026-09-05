# Serialize per-vault mutations so retries cannot create duplicates or apply a
# weight increment twice. Store the response, not an additional raw request copy.
class Mnemodyne::Write

  class Conflict < StandardError; end
  class InvalidKey < StandardError; end

  def self.call(vault:, key:, operation:, payload:)
    raise InvalidKey unless key.is_a?(String) && key.match?(/\A[a-zA-Z0-9_.:-]{1,128}\z/)

    digest = Digest::SHA256.hexdigest(JSON.generate(canonical([ operation, payload ])))
    vault.with_lock do
      raise Conflict if vault.erasure_requested_at? || vault.suspended_at?
      previous = vault.operations.find_by(key: key)
      if previous
        raise Conflict unless previous.request_digest == digest
        return previous.result
      end

      result = yield.as_json
      vault.operations.create!(key: key, request_digest: digest, result: result)
      result
    end
  end

  def self.canonical(value)
    case value
    when Hash then value.stringify_keys.sort.to_h.transform_values { |child| canonical(child) }
    when Array then value.map { |child| canonical(child) }
    else value
    end
  end
  private_class_method :canonical

end
