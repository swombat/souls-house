# frozen_string_literal: true

require "openssl"

module House
  # Read-only deploy preflight, not certificate issuance or a trust-store check.
  module StoneTls

    class InvalidCertificate < StandardError; end

    def self.validate!(secrets:, house_hosts:, stones_domain:, now: Time.now)
      certificate = OpenSSL::X509::Certificate.new(secrets["HOUSE_TLS_CERTIFICATE_PEM"])
      # An explicit password prevents OpenSSL prompting for encrypted keys.
      key = OpenSSL::PKey.read(secrets["HOUSE_TLS_PRIVATE_KEY_PEM"], "")
      key.private_to_der # Reject a public key, even if its public component matches.

      unless certificate.check_private_key(key)
        raise InvalidCertificate, "Stone TLS certificate and private key do not match"
      end
      unless certificate.not_before <= now && now < certificate.not_after
        raise InvalidCertificate, "Stone TLS certificate is expired or not yet valid"
      end
      unless dns_names(certificate).include?("*.#{stones_domain}")
        raise InvalidCertificate, "Stone TLS certificate requires an explicit wildcard DNS SAN"
      end
      hosts = house_hosts + [ "stone-tls-preflight.#{stones_domain}" ]
      unless hosts.all? { |host| OpenSSL::SSL.verify_certificate_identity(certificate, host) }
        raise InvalidCertificate, "Stone TLS certificate must cover every house host and the stone wildcard"
      end
      true
    rescue OpenSSL::OpenSSLError, ArgumentError, TypeError
      # Never include parser messages or input; PEM and key contents stay private.
      raise InvalidCertificate, "Stone TLS certificate or private key is missing, invalid, or encrypted"
    end

    def self.dns_names(certificate)
      certificate.extensions.select { |extension| extension.oid == "subjectAltName" }.flat_map do |extension|
        encoded_names = OpenSSL::ASN1.decode(extension.to_der).value.last.value
        OpenSSL::ASN1.decode(encoded_names).value.filter_map do |name|
          name.value if name.tag_class == :CONTEXT_SPECIFIC && name.tag == 2
        end
      end
    end
    private_class_method :dns_names

  end
end
