class Api::V1::Memory::BaseController < Api::V1::BaseController

  before_action :require_resident!
  before_action :require_vault!
  before_action :validate_request_bounds!

  rescue_from ActiveRecord::RecordInvalid do |error|
    render json: { error: "Invalid attributes", fields: error.record.errors.attribute_names }, status: :unprocessable_entity
  end
  rescue_from ActiveRecord::RecordNotUnique, Mnemodyne::Write::Conflict do
    render json: { error: "Conflicting write" }, status: :conflict
  end
  rescue_from Mnemodyne::Erasure::Invalid, Mnemodyne::Write::InvalidKey, ActionController::ParameterMissing, ArgumentError, KeyError do
    render json: { error: "Invalid request" }, status: :bad_request
  end

  private

  # Runs before ActionController's instrumentation publishes request parameters.
  # Handles, queries, receipts and graph metadata must not enter ordinary logs.
  def process_action(*)
    request.set_header("action_dispatch.parameter_filter", [ /./ ])
    response.set_header("Cache-Control", "no-store")
    super
  end

  def require_resident!
    @resident = @current_api_key.agent
    unless @resident&.externally_hosted? && @resident.account_id == @current_api_key.account_id &&
        !@resident.account.disabled? && @resident.active?
      render json: { error: "An active external resident credential is required" }, status: :forbidden
    end
  end

  def require_vault!
    @vault = @resident.memory_vault
    if !@vault
      render json: { error: "Memory is not enabled" }, status: :not_found
    elsif @vault.suspended_at?
      render json: { error: "Memory is suspended" }, status: :forbidden
    end
  end

  def write(operation, payload, &block)
    Mnemodyne::Write.call(vault: @vault, key: request.headers["Idempotency-Key"],
      operation: operation, payload: payload, &block)
  end

  def validate_request_bounds!
    raise ArgumentError if request.raw_post.to_s.bytesize > 65_536
    [ :id, :after, :node_id ].each do |key|
      next if params[key].nil?
      raise ArgumentError unless params[key].is_a?(String) && params[key].match?(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i)
    end
  end

  def object_params(key)
    value = params.require(key)
    raise ArgumentError unless value.is_a?(ActionController::Parameters)
    value
  end

  def bounded_limit
    limit = Integer(params.fetch(:limit, 100))
    raise ArgumentError unless limit.between?(1, 100)
    limit
  end

  def node_json(node)
    node.as_json(except: [ :vault_id, :embedding, :embedding_digest ])
  end

  def edge_json(edge)
    edge.as_json(except: [ :vault_id ])
  end

end
