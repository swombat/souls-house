module Visitors
  # Where a visitor's turn goes instead of a runtime (JdWxAj). The run is
  # reserved and claimed like any resident's, so the room's receipts and
  # "already responding" read the same, then it waits as a VisitorWake until
  # the visitor's home collects it. Nothing here calls out.
  class WakeRelay

    def initialize(agent:, chat:, interaction: nil, wake_source_kinds: [], requested_at: nil)
      @agent = agent
      @chat = chat
      @interaction = interaction
      @wake_source_kinds = wake_source_kinds
      @requested_at = requested_at
    end

    def call
      admission = @agent.visitor_admission
      unless admission&.current?
        raise Agent::RuntimeAvailability::Unavailable.new("#{@agent.name}'s visit has ended", code: "visit_ended")
      end

      @interaction ||= AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat,
        wake_source_kinds: @wake_source_kinds, requested_at: @requested_at)
      return { status: 409, body: { "status" => "already_running" } } unless @interaction.claim_dispatch!

      wake = nil
      admission.with_lock do
        unless admission.current?
          @interaction.with_lock { @interaction.finish_execution!("cancelled") }
          raise Agent::RuntimeAvailability::Unavailable.new("#{@agent.name}'s visit has ended", code: "visit_ended")
        end

        @interaction.update!(
          endpoint_url: "visit://#{admission.to_param}",
          request_text: "",
          transport_status: 202,
          execution_state: "running",
          execution_deadline_at: (VisitorWake::COLLECTION_WINDOW + VisitorWake::RUN_WINDOW).from_now
        )
        wake = VisitorWake.open_for!(interaction: @interaction, admission: admission, chat: @chat,
          reason: wake_reason)
      end
      { status: 202, body: { "status" => "queued", "visit_wake_id" => wake.to_param } }
    end

    private

    def wake_reason
      return "handoff" if @interaction.message_handoffs.exists?
      return "mention" if @wake_source_kinds.include?("human") || @wake_source_kinds.include?("mention")

      @wake_source_kinds.first.presence || "conversation"
    end

  end
end
