module Api
  module V1
    module HostRunner
      # The runner's command channel (#238). It polls; Rails answers at once
      # with at most one command, and never calls the VM.
      class CommandsController < BaseController

        def next
          raise RunnerSignature::Invalid.new(:unknown_runner) unless enrollment.enrolled?

          nonce = verify_signature!(enrollment.public_key)
          render json: { command: enrollment.poll!(nonce:) }
        end

        def result
          raise RunnerSignature::Invalid.new(:unknown_runner) unless enrollment.enrolled?

          nonce = verify_signature!(enrollment.public_key)
          enrollment.report_command_result!(public_id: params[:id], result: payload, nonce:)
          render json: { status: "recorded" }
        end

      end
    end
  end
end
