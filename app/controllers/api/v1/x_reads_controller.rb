module Api
  module V1
    class XReadsController < BaseController

      ACTION = "x_read"

      def create
        unless current_api_agent
          return render json: { error: "X reading is only available to agent API keys" }, status: :forbidden
        end

        reader = XReader.new
        prepared = reader.prepare(
          operation: params[:operation],
          query: params[:query],
          url: params[:url],
          question: params[:question],
          handles: params[:handles],
          from_date: params[:from_date],
          to_date: params[:to_date]
        )
        admission = MeteredActionEvent.admit!(action: ACTION, agent: current_api_agent)
        return render_limit(admission) unless admission.allowed?

        result = reader.call(prepared)
        allowance = complete_event(
          admission.event,
          outcome: "completed",
          provider_request_id: result[:provider_request_id],
          usage: result[:usage],
          cost_in_usd_ticks: result.dig(:usage, :cost_in_usd_ticks)
        )
        render json: result.except(:provider_request_id).merge(
          request_id: admission.request_id,
          rate_limits: allowance.as_json
        )
      rescue XReader::InvalidRequest => e
        render_reader_error(e, status: :unprocessable_entity)
      rescue XReader::ConfigurationError => e
        render_reader_error(e, status: :service_unavailable)
      rescue XReader::UpstreamError => e
        allowance = if defined?(admission) && admission&.event
          complete_event(
            admission.event,
            outcome: "upstream_error",
            provider_request_id: e.provider_request_id,
            usage: e.usage,
            cost_in_usd_ticks: e.cost_in_usd_ticks
          )
        else
          current_allowance
        end
        render json: {
          error: e.message,
          request_id: allowance.request_id,
          rate_limits: allowance.as_json
        }, status: :bad_gateway
      end

      private

      def render_limit(admission)
        retry_after = admission.retry_at && [ (admission.retry_at - Time.current).ceil, 1 ].max
        response.set_header("Retry-After", retry_after.to_s) if retry_after
        render json: {
          error: "X reading limit reached; try again after a slot becomes available",
          request_id: admission.request_id,
          rate_limits: admission.as_json
        }, status: :too_many_requests
      end

      def render_reader_error(error, status:)
        allowance = current_allowance
        render json: {
          error: error.message,
          request_id: allowance.request_id,
          rate_limits: allowance.as_json
        }, status:
      end

      def current_allowance
        MeteredActionEvent.allowance(action: ACTION, agent: current_api_agent)
      end

      def complete_event(event, **attributes)
        event.complete!(**attributes)
      rescue StandardError => e
        Rails.logger.error("[XReadsController] metering completion failed for #{event.request_id}: #{e.class}: #{e.message}")
        Honeybadger.notify(e, context: { request_id: event.request_id, action: ACTION }) if defined?(Honeybadger)
        MeteredActionEvent.allowance(
          action: ACTION,
          agent: current_api_agent,
          request_id: event.request_id,
          request_counted: true,
          event:
        )
      end

    end
  end
end
