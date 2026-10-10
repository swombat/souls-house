module Api
  module V1
    module HostRunner
      class BackupsController < BaseController

        BASE_PATH = "/api/v1/host_runner/backup"
        READ_CHUNK = 1.megabyte

        # A factory keeps tests entirely credential-free, including the bucket.
        REPOSITORY_FACTORY = ->(agent) { Backup::VmRepository.new(agent:) }
        class_attribute :repository_factory, default: REPOSITORY_FACTORY

        rescue_from Backup::VmRepository::Refused do |error|
          refuse(error.code, error.status)
        end

        rescue_from ActiveRecord::QueryCanceled, ActiveRecord::LockWaitTimeout do
          refuse(:backup_database_timeout, :service_unavailable)
        end

        rescue_from Aws::S3::Errors::ServiceError, Seahorse::Client::NetworkingError do
          refuse(:backup_storage_unavailable, :service_unavailable)
        end

        def repository
          response.headers["Cache-Control"] = "no-store"
          # Journey normalizes PATH_INFO (including trailing slashes). The
          # original target is the actual REST wire path and signed string.
          target = request.original_fullpath
          wire_path, query = target.split("?", 2)
          path = wire_path.delete_prefix("#{BASE_PATH}/")
          path = "" if wire_path == BASE_PATH
          operation = Backup::VmRepository.operation(method: request.request_method, path:, query: query.to_s)

          body = backup_body
          raise Backup::VmRepository::Refused.new(:unexpected_backup_body, 400) if operation != :create && body.present?

          Backup::VmRepository.with_database_limits do
            # Authenticate before taking scarce storage slots. A busy retry
            # needs a fresh nonce: authorization consumes it exactly once.
            nonce = RunnerSignature.verify!(
              method: request.request_method, path: target, body:,
              headers: request.headers, public_key_b64: enrollment.public_key,
              expected_runner_id: enrollment.public_id, max_body_bytes: Backup::VmRepository::MAX_BYTES
            )
            agent = enrollment.authorize_backup!(nonce:)
            repository = self.class.repository_factory.call(agent)
            Backup::VmRepository::Admission.with(enrollment.id) do
              serve(repository, operation, path, body)
            end
          end
        end

        private

        def backup_body
          raise Backup::VmRepository::Refused.new(:backup_object_too_large, 413) if request.content_length.to_i > Backup::VmRepository::MAX_BYTES

          body = +"".b
          input = request.body
          return body unless input

          loop do
            chunk = input.read([ READ_CHUNK, Backup::VmRepository::MAX_BYTES + 1 - body.bytesize ].min)
            break if chunk.nil? || chunk.empty?

            body << chunk
            raise Backup::VmRepository::Refused.new(:backup_object_too_large, 413) if body.bytesize > Backup::VmRepository::MAX_BYTES
          end
          body
        end

        def serve(repository, operation, path, body)
          # Range and Accept are deliberately unsigned read-only selectors;
          # they cannot choose a repository or mutate stored bytes.
          case operation
          when :init
            repository.init!
            head :ok
          when :create
            repository.create(path, body)
            head :ok
          when :delete
            repository.delete_lock(path)
            head :ok
          when :head
            response.headers["Content-Length"] = repository.head(path).to_s
            head :ok, content_type: "application/octet-stream"
          when :read
            result = repository.read(path, range: request.headers["Range"].presence)
            response.headers["Content-Range"] = result[:content_range] if result[:content_range]
            response.headers["Accept-Ranges"] = "bytes"
            render body: result[:body], content_type: "application/octet-stream", status: result[:content_range] ? :partial_content : :ok
          when :list
            entries = repository.list(path.delete_suffix("/"))
            v2 = request.headers["Accept"].to_s.split(",").any? { |type| type.strip.split(";").first == Backup::VmRepository::V2_MEDIA_TYPE }
            render json: v2 ? entries : entries.pluck(:name), content_type: v2 ? Backup::VmRepository::V2_MEDIA_TYPE : "application/json"
            # restic only parses a v2 listing when Content-Type is exactly the v2 media type. Rails would
            # append "; charset=utf-8", and restic would then read it as v1 and fail (live check, 2026-10-10).
            response.charset = false if v2
          end
        end

      end
    end
  end
end
