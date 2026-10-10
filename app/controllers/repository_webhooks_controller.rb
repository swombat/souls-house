# GitHub's deliveries for a connected repository (WatchedRepository). No
# session, no CSRF: the receiver token finds the repository and the
# X-Hub-Signature-256 HMAC of the raw body proves GitHub sent it with the
# hook's secret. The body is bounded in front of the app
# (RepositoryWebhookBodyLimit). Nothing from the payload is fetched or run;
# whitelisted fields are copied and the work happens in RepositoryDeliveryJob.
class RepositoryWebhooksController < ActionController::API

  def receive
    repository = WatchedRepository.live.find_by(receiver_token: params[:receiver_token].to_s)
    return head(:not_found) unless repository

    raw = request.raw_post.to_s
    return head(:content_too_large) if raw.bytesize > RepositoryWebhookBodyLimit::MAX_BODY_BYTES

    unless repository.verify_signature(raw, request.headers["X-Hub-Signature-256"])
      repository.record_delivery_result!("rejected")
      return head(:unauthorized)
    end

    guid = request.headers["X-GitHub-Delivery"].to_s
    event = request.headers["X-GitHub-Event"].to_s
    return head(:bad_request) if guid.blank? || guid.length > 100 || event.blank? || event.length > 100

    payload = JSON.parse(raw)
    return head(:bad_request) unless payload.is_a?(Hash)

    interesting = event.in?(%w[workflow_run deployment_status])
    delivery = RepositoryDelivery.insert_all(
      [ {
        watched_repository_id: repository.id,
        delivery_guid: guid,
        event: event,
        action: payload["action"].to_s.first(50).presence,
        received_at: Time.current,
        signature_ok: true,
        payload: RepositoryDelivery.reduce_payload(event, payload),
        processed_at: (Time.current unless interesting),
        created_at: Time.current,
        updated_at: Time.current
      } ],
      unique_by: :delivery_guid,
      returning: %w[id]
    ).rows.first
    # A redelivery of something already received is acknowledged, not
    # redone; but if the first receipt was never processed (its job lost),
    # this is the moment to try again.
    unless delivery
      existing = repository.repository_deliveries.outstanding.find_by(delivery_guid: guid)
      RepositoryDeliveryJob.perform_later(existing.id) if existing && interesting
      return head(:ok)
    end

    repository.confirm_hook! if event == "ping"
    repository.record_delivery_result!(interesting ? "verified" : "ignored")
    RepositoryDeliveryJob.perform_later(delivery.first) if interesting
    head :ok
  rescue JSON::ParserError
    head :bad_request
  end

end
