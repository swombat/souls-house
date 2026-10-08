module Api
  module V1
    module HostRunner
      # Resident images are built on the house host and pushed nowhere, so the
      # house hands them to its VMs itself (#238 part 3). The runner verifies
      # the loaded image ID against the one its start_resident pinned.
      class ImagesController < BaseController

        include ActionController::Live

        CHUNK = 1.megabyte

        def show
          raise RunnerSignature::Invalid.new(:unknown_runner) unless enrollment.enrolled?

          nonce = verify_signature!(enrollment.public_key)
          image_id = enrollment.authorize_image!(image_id: params[:id], nonce:)
          # Every refusal above renders normally; the stream opens only now.
          stream(image_id)
        end

        private

        def stream(image_id)
          response.headers["Content-Type"] = "application/x-tar"
          response.headers["Cache-Control"] = "no-store"
          response.headers["Last-Modified"] = Time.current.httpdate
          response.headers["X-Accel-Buffering"] = "no"
          self.class.image_source.call(image_id) { |chunk| response.stream.write(chunk) }
        rescue ActionController::Live::ClientDisconnected, IOError
          nil
        ensure
          response.stream.close
        end

        # docker save of exactly one image ID; replaced in tests.
        def self.image_source_default = IMAGE_SOURCE

        IMAGE_SOURCE = lambda { |image_id, &block|
          IO.popen([ "docker", "save", image_id ], "rb") do |io|
            while (chunk = io.read(CHUNK))
              block.call(chunk)
            end
          end
          raise IOError, "docker save failed" unless $?.success?
        }
        class_attribute :image_source, default: IMAGE_SOURCE

      end
    end
  end
end
