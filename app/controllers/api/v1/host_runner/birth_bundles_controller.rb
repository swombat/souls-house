module Api
  module V1
    module HostRunner
      # The runner a new VM's user_data pins (#779). The VM has no key yet, so
      # this one read is authorised by the enrollment's one-time token, sent
      # as a bearer header and checked without being spent.
      class BirthBundlesController < BaseController

        def show
          bytes = enrollment.authorize_birth_bundle!(token: bearer_token, sha256: params[:id])
          response.headers["Cache-Control"] = "no-store"
          send_data bytes, type: "application/x-xz", disposition: "attachment", filename: "runner.tar.xz"
        end

        private

        def bearer_token
          scheme, token = request.authorization.to_s.split(" ", 2)
          raise RunnerEnrollment::Refused.new(:invalid_token, 401) unless scheme == "Bearer" && token.present?

          token
        end

      end
    end
  end
end
