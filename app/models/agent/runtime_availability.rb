module Agent::RuntimeAvailability

  extend ActiveSupport::Concern

  HOSTED_RUNTIMES = %w[external offline provisioning].freeze
  CONVERSATION_RUNTIMES = %w[external offline].freeze
  RETIRED_RUNTIMES = %w[deprecated inline migrating].freeze

  class Unavailable < ArgumentError

    attr_reader :code

    def initialize(message, code: "agent_unavailable")
      @code = code
      super(message)
    end

  end

  included do
    scope :hosted, -> { where(runtime: HOSTED_RUNTIMES) }
    scope :eligible_for_conversation, -> { active.where(runtime: CONVERSATION_RUNTIMES) }
  end

  # Legacy values fail closed before the reviewed one-time data transition too.
  def deprecated?
    runtime.in?(RETIRED_RUNTIMES)
  end

  def hosted?
    runtime.in?(HOSTED_RUNTIMES)
  end

  def eligible_for_conversation?
    active? && runtime.in?(CONVERSATION_RUNTIMES)
  end

  def unavailability_reason
    return "agent_deprecated" if deprecated?
    return "agent_inactive" unless active?
    return "agent_provisioning" if provisioning?
    "agent_unavailable" unless eligible_for_conversation?
  end

  def require_conversation_runtime!
    return if eligible_for_conversation?

    raise Unavailable.new(
      "#{name} is unavailable#{deprecated? ? ': its inline runtime has been retired' : ''}",
      code: unavailability_reason
    )
  end

end
