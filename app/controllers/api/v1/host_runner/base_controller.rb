module Api
  module V1
    module HostRunner
      # Host runners authenticate with Ed25519-signed requests, not API keys.
      # Telemetry only: nothing here can start, stop or reach a resident.
      class BaseController < ActionController::API

        rescue_from RunnerSignature::Invalid do |error|
          refuse(error.code, :unauthorized)
        end

        rescue_from RunnerEnrollment::Refused do |error|
          refuse(error.code, error.status)
        end

        private

        def enrollment
          @enrollment ||= RunnerEnrollment.find_by(public_id: request.headers["X-Runner-Id"].to_s) ||
            raise(RunnerSignature::Invalid.new(:unknown_runner))
        end

        def raw_body
          if request.content_length.to_i > RunnerSignature::MAX_BODY_BYTES
            raise RunnerSignature::Invalid.new(:body_too_large)
          end

          @raw_body ||= request.raw_post.to_s
        end

        def payload
          @payload ||= JSON.parse(raw_body).then { |value| value.is_a?(Hash) ? value : {} }
        rescue JSON::ParserError
          @payload = {}
        end

        # Verifies the signature and returns the nonce. Writes nothing: the
        # model consumes the nonce in the same transaction as its own change,
        # after every eligibility check.
        def verify_signature!(public_key_b64)
          RunnerSignature.verify!(
            method: request.request_method, path: request.path, body: raw_body,
            headers: request.headers, public_key_b64:, expected_runner_id: enrollment.public_id
          )
        end

        def facts
          value = payload["facts"]
          value.is_a?(Hash) ? value.slice(*FACT_KEYS) : {}
        end

        def reported_server_id
          value = payload.dig("facts", "provider_server_id")
          value.is_a?(Integer) ? value : nil
        end

        FACT_KEYS = %w[
          provider_server_id docker_version runtime_image_digest disk_total_bytes
          disk_free_bytes memory_total_kib uptime_seconds runner_version
        ].freeze

        def refuse(code, status)
          Rails.logger.warn("[host_runner] refused #{code} runner=#{request.headers['X-Runner-Id'].to_s.first(40)}")
          render json: { error: code.to_s }, status:
        end

      end
    end
  end
end
