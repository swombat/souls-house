# Executed inside the current web container, with parameters via ENV, for a
# resident whose container lives on its own VM. The house never calls the VM:
# a new runtime reaches it as a start_resident command its runner polls for,
# pinned by image ID (Agents::RemoteRuntime.start!). stdout is private to the
# host worker. Only explicitly projected fields leave it.
#
# DEPLOY_VM_MODE:
#   inspect  the image ID the VM last confirmed running, and whether it is
#            reachable now (placement ready, runner live, last start done)
#   start    between turns only, under the turn gate: point the resident at
#            the new image and queue its restart as a refresh, which holds
#            turn admission until the runner's answer settles it
#   status   settle that restart; healthy only when the runner confirmed the
#            exact new image ID
require "json"

a = Agent.find(Integer(ENV.fetch("DEPLOY_RESIDENT_ID")))
mode = ENV.fetch("DEPLOY_VM_MODE")
image_id_pattern = Agents::RemoteRuntime::IMAGE_ID

placement = Agents::RemoteRuntime.placement_for(a)
raise "Resident is not on a VM" unless placement&.backend == "hetzner_cloud"

# The image ID in the runner's own answer to its latest finished start.
running_image = -> {
  enrollment = Agents::RemoteRuntime.enrollment_for(a)
  next nil unless enrollment

  last = enrollment.commands.where(kind: %w[start_resident stop_resident]).where.not(finished_at: nil)
    .order(:finished_at, :id).last
  next nil unless last&.kind == "start_resident" && last.state == "done"

  image = last.result.to_h.dig("result", "image").to_s
  image_id_pattern.match?(image) ? image : nil
}

result =
  case mode
  when "inspect"
    image = Agents::RemoteRuntime.running?(a) ? running_image.call : nil
    { result: "inspected", id: a.id, running: image.present?, image: image }
  when "start"
    target = ENV.fetch("DEPLOY_RESIDENT_IMAGE")
    target_id = ENV.fetch("DEPLOY_RESIDENT_IMAGE_ID")
    raise "Target must be an image ID" unless image_id_pattern.match?(target_id)

    if !Agents::RemoteRuntime.running?(a)
      { result: "unavailable", id: a.id }
    elsif a.container_image == target && running_image.call == target_id
      { result: "current", id: a.id }
    else
      outcome = nil
      begin
        Agent.transaction do
          Agent.connection.execute("SET LOCAL lock_timeout = '5s'")
          # The turn gate first, then the agent row, in the same order as
          # turn admission and begin_refresh!, so neither can deadlock this.
          Agent.connection.execute("SELECT pg_advisory_xact_lock(#{Agents::RemoteRuntime::TURN_GATE})")
          a.lock!
          a.update!(container_image: target)
          command = Agents::RemoteRuntime.begin_refresh!(a)
          if command == :busy
            outcome = { result: "busy", id: a.id }
            raise ActiveRecord::Rollback
          end
          # start! resolved the tag on this host; it must be the image the
          # worker built and checked, or nothing goes to the VM.
          sent = JSON.parse(command.payload_json.to_s)["image"]
          raise "Queued image is not the built image" unless sent == target_id

          outcome = { result: "started", id: a.id, command_id: command.id }
        end
      rescue ActiveRecord::LockWaitTimeout
        outcome = { result: "busy", id: a.id }
      end
      outcome
    end
  when "status"
    target_id = ENV.fetch("DEPLOY_RESIDENT_IMAGE_ID")
    command_id = Integer(ENV.fetch("DEPLOY_VM_COMMAND_ID"))
    command = RunnerCommand.find_by(id: command_id, agent_placement_id: placement.id)
    raise "Restart command is not this resident's" unless command

    settled = Agents::RemoteRuntime.settle_refresh!(placement)
    if %i[pending recovering].include?(settled)
      { result: "pending", id: a.id }
    elsif settled == :done && placement.reload.refresh_command_id.nil? && running_image.call == target_id
      { result: "healthy", id: a.id }
    else
      # :held, or settled without the new image confirmed. The hold (if any)
      # keeps turns out until an operator looks at the VM.
      { result: "failed", id: a.id }
    end
  else
    raise "Unknown mode"
  end

puts result.to_json
