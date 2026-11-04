# Account archives are private data: responses are never cached and request
# parameters (an upload, a filename) never reach the logs.
module Accounts::PortabilityPrivacy

  extend ActiveSupport::Concern

  included do
    before_action :private_response
  end

  private

  def private_response
    response.headers["Cache-Control"] = "private, no-store"
    request.set_header("action_dispatch.parameter_filter", [ /./ ])
  end

  def process_action(*)
    request.set_header("action_dispatch.parameter_filter", [ /./ ])
    super
  end

end
