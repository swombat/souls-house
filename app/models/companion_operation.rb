class CompanionOperation < ApplicationRecord

  include ObfuscatesId

  class Refused < StandardError; end

  READ_KINDS = %w[drives list stat search read].freeze
  WRITE_KINDS = %w[mkdir write copy move rename trash].freeze
  ARGUMENT_KEYS = {
    "mkdir" => %w[volume path],
    "write" => %w[volume path mode input_size],
    "copy" => %w[source_volume source_path volume path],
    "move" => %w[source_volume source_path volume path],
    "rename" => %w[volume path destination],
    "trash" => %w[volume path quarantine],
    "execute" => %w[input_size timeout_seconds]
  }.freeze
  # Desktop arguments are validated in full by the companion's allowlisted
  # grammar; the house checks the outer shape and the grant.
  DESKTOP_KEYS = %w[command app steps timeout_seconds interactive compact skeleton max_depth surface root
    window_id wait_for wait_timeout_ms role name value text description native_id exact first last count nth
    limit ref property combo direction amount].freeze
  DESKTOP_MAX_ARGUMENTS = 24.kilobytes
  ACTIVE_STATES = %w[pending dispatched].freeze
  MAX_BODY = 8.megabytes
  MAX_INLINE = 64.kilobytes
  SAFE_ERRORS = %w[denied cancelled deadline invalid unsupported unavailable changed failed].freeze

  belongs_to :companion_device
  belongs_to :agent
  has_one :body, class_name: "CompanionOperationBody", dependent: :destroy
  has_one :input, class_name: "CompanionOperationInput", dependent: :destroy

  def self.start!(device:, agent:, kind:, arguments:)
    raise Refused, "Unsupported operation" unless READ_KINDS.include?(kind) || ARGUMENT_KEYS.key?(kind) || kind == "desktop"
    limit = kind == "desktop" ? DESKTOP_MAX_ARGUMENTS : 8.kilobytes
    raise Refused, "Invalid arguments" unless arguments.is_a?(Hash) && arguments.to_json.bytesize <= limit
    keys = kind == "desktop" ? DESKTOP_KEYS : ARGUMENT_KEYS.fetch(kind, %w[volume path offset limit pattern cursor])
    raise Refused, "Unexpected arguments" unless (arguments.keys - keys).empty?
    if %w[write execute].include?(kind)
      size = arguments["input_size"]
      raise Refused, "Invalid input size" unless size.is_a?(Integer) && size.between?(0, MAX_BODY)
    end
    if kind == "write"
      raise Refused, "Invalid write mode" unless %w[create overwrite append].include?(arguments.fetch("mode", "create"))
    end
    if kind == "desktop"
      raise Refused, "Invalid desktop command" unless arguments["command"].is_a?(String)
      if arguments["command"] == "batch"
        steps = arguments["steps"]
        raise Refused, "Invalid batch" unless steps.is_a?(Array) && steps.size.between?(1, 16) &&
          steps.all? { |step| step.is_a?(Hash) && (step.keys - DESKTOP_KEYS - %w[steps timeout_seconds]).empty? &&
            step.keys.exclude?("steps") && step.keys.exclude?("timeout_seconds") }
      end
    end
    timeout = %w[execute desktop].include?(kind) ? arguments.fetch("timeout_seconds", 30) : 30
    maximum = kind == "desktop" ? 120 : 300
    raise Refused, "Invalid timeout" unless timeout.is_a?(Integer) && timeout.between?(1, maximum)

    device.with_lock do
      where(companion_device: device, state: ACTIVE_STATES).where(deadline: ..Time.current).update_all(state: "timed_out", outcome: "deadline")
      raise Refused, "Device unavailable" unless device.revoked_at.nil? && !device.paused? && device.connection_epoch.present?
      raise Refused, "Grant denied" unless permitted?(device, agent, kind, arguments)
      raise Refused, "Device busy" if where(companion_device: device, state: ACTIVE_STATES).count >= 4

      deadline = timeout.seconds.from_now
      if kind == "desktop"
        # The durable row keeps a receipt (verbs and apps only). Typed text,
        # refs and the rest live in the expiring input row until dispatch.
        operation = create!(companion_device: device, agent: agent, kind: kind, arguments: desktop_receipt(arguments),
          connection_epoch: device.connection_epoch, grant_revision: device.grant_revision, deadline: deadline)
        operation.create_input!(data: JSON.generate(arguments).b, expires_at: [ deadline, 10.minutes.from_now ].min)
        operation
      else
        create!(companion_device: device, agent: agent, kind: kind, arguments: arguments,
          connection_epoch: device.connection_epoch, grant_revision: device.grant_revision, deadline: deadline)
      end
    end
  end

  def self.desktop_receipt(arguments)
    receipt = arguments.slice("command", "app", "timeout_seconds")
    if arguments["command"] == "batch"
      receipt["steps"] = arguments["steps"].map { |step| step.slice("command", "app") }
    end
    receipt
  end

  def self.permitted?(device, agent, kind, arguments)
    return false if device.account.reload.disabled? || agent.account_id != device.account_id || !agent.reload.active?

    resident = device.policy.fetch("residents", []).find { |r| r["id"] == agent.obfuscated_id }
    return false unless resident
    return true if kind == "drives"
    return resident["execute"] == true if kind == "execute"
    return resident["desktop"] == true if kind == "desktop"

    grants = resident.fetch("volumes", [])
    allowed = ->(volume, write) do
      grants.any? { |g| g["volume"] == volume && (write ? g["access"] == "write" : %w[read write].include?(g["access"])) }
    end
    return false unless allowed.call(arguments["volume"], WRITE_KINDS.include?(kind))
    return allowed.call(arguments["source_volume"], kind == "move") if %w[copy move].include?(kind)

    true
  end

  def input_required?
    kind.in?(%w[write execute])
  end

  # The upload is actor/device/operation-bound; never place file bytes, argv or
  # stdin in the long-lived arguments/audit row or on the Cable envelope.
  def attach_input!(data)
    companion_device.with_lock do
      with_lock do
        raise Refused, "Input unavailable" unless state == "pending" && input_required? && deliverable?
        raise Refused, "Input already supplied" if input
        raise Refused, "Invalid input size" unless data.is_a?(String) && data.bytesize == arguments["input_size"] && data.bytesize <= MAX_BODY

        create_input!(data: data.b, expires_at: [ deadline, 10.minutes.from_now ].min)
      end
    end
  end

  def take_input!(epoch:, revision:)
    companion_device.with_lock do
      with_lock do
        return unless state == "dispatched" && epoch == connection_epoch && revision == grant_revision && deliverable?

        saved = input
        return unless saved
        data = saved.expires_at.future? ? saved.data : nil
        saved.destroy!
        data
      end
    end
  end

  # The row exists before any broadcast. Reconnect never replays it.
  def dispatch!
    companion_device.with_lock do
      with_lock do
        return false unless state == "pending" && deliverable?
        return false if input_required? && (!input || input.expires_at <= Time.current)

        message = envelope
        if kind == "desktop"
          saved = input
          return false unless saved && saved.expires_at > Time.current

          # The full payload goes out once, in flight only, and is gone after.
          message[:arguments] = JSON.parse(saved.data)
          saved.destroy!
        end
        update!(state: "dispatched")
        CompanionChannel.broadcast_to(companion_device, message)
        true
      end
    end
  end

  def envelope
    { type: "request", request_id: obfuscated_id, device_id: companion_device.obfuscated_id,
      resident_id: agent.obfuscated_id, grant_revision: grant_revision, connection_epoch: connection_epoch,
      deadline: deadline.iso8601(6), operation: kind, arguments: arguments, input_required: input_required?,
      policy: companion_device.policy }
  end

  def deliverable?
    device = companion_device
    device.revoked_at.nil? && !device.paused? && device.connection_epoch == connection_epoch &&
      device.grant_revision == grant_revision && deadline.future? &&
      self.class.permitted?(device, agent, kind, arguments)
  end

  # Both dispatch and delivery hold the device lock before the operation lock.
  # Contents live separately and expire, while the safe operation audit remains.
  def complete!(epoch:, revision:, data: nil, content_type: "application/json", error: nil)
    companion_device.with_lock do
      with_lock do
        return false unless state == "dispatched"
        unless epoch == connection_epoch && revision == grant_revision && deliverable?
          update!(state: "cancelled", outcome: "changed")
          return false
        end
        if error
          update!(state: "failed", outcome: SAFE_ERRORS.include?(error) ? error : "failed")
        else
          raise Refused, "Result too large" unless data.is_a?(String) && data.bytesize <= MAX_BODY
          raise Refused, "Invalid content type" unless %w[application/json application/octet-stream].include?(content_type)
          create_body!(data: data.b, content_type: content_type, expires_at: 10.minutes.from_now)
          update!(state: "completed", outcome: "ok")
          CompanionBodyExpiryJob.set(wait: 10.minutes).perform_later(body.id)
        end
        true
      end
    end
  end

  def take_body!
    companion_device.with_lock do
      with_lock do
        unless state == "completed" && deliverable?
          body&.destroy!
          return
        end
        saved = body
        return unless saved
        data = saved.expires_at.future? ? [ saved.data, saved.content_type ] : nil
        saved.destroy!
        data
      end
    end
  end

end
