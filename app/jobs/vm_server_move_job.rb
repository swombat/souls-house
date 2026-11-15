# Carries one move of a resident between servers forward a step at a time
# (Agents::ServerMove), and comes back while it is still open. Each step
# reads the provider first, so running it twice or after a restart is safe.
# VmBirthSweepJob starts it again if a move is left open with no job.
class VmServerMoveJob < ApplicationJob

  queue_as :default

  RECHECK_AFTER = 20.seconds

  def perform(move_id)
    move = VmServerMove.find_by(id: move_id)
    return if move.nil?

    mover = Agents::ServerMove.new
    if move.phase == "releasing"
      move = mover.finish_release!(move)
    elsif move.open?
      move = mover.step!(move)
    end
    self.class.set(wait: RECHECK_AFTER).perform_later(move.id) if move.open? || move.phase == "releasing"
  end

end
