module Api
  module V1
    module HostRunner
      # A new VM resident's first home (#246 slice 3). Served only to the
      # placement's own runner, and only while a delivered seed_home of the
      # current generation names exactly this digest.
      class SeedsController < BaseController

        def show
          raise RunnerSignature::Invalid.new(:unknown_runner) unless enrollment.enrolled?

          nonce = verify_signature!(enrollment.public_key)
          archive = enrollment.authorize_seed!(sha256: params[:id], nonce:)
          response.headers["Cache-Control"] = "no-store"
          send_data archive, type: "application/gzip", disposition: "attachment", filename: "home.tar.gz"
        end

      end
    end
  end
end
