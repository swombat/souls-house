module Api
  module V1
    module HostRunner
      # The house's current runner bundle (#593): the same compacted two-file
      # tar.xz a VM gets at birth. Served only to the enrollment's own runner,
      # and only while a delivered update_runner names exactly this digest.
      class RunnerBundlesController < BaseController

        def show
          raise RunnerSignature::Invalid.new(:unknown_runner) unless enrollment.enrolled?

          nonce = verify_signature!(enrollment.public_key)
          bytes = enrollment.authorize_runner_bundle!(sha256: params[:id], nonce:)
          response.headers["Cache-Control"] = "no-store"
          send_data bytes, type: "application/x-xz", disposition: "attachment", filename: "runner.tar.xz"
        end

      end
    end
  end
end
