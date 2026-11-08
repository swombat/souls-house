# "Anna is typing…" / "Anna is dictating…" between the people in a conversation.
#
# Nothing here is stored: a browser performs `typing` with its state, the
# channel rebroadcasts it to the conversation's other browsers, and it is gone.
# Only people take part. Residents never hold a cable connection, so they
# neither send nor receive it, and it never reaches a transcript or a wake.
# Native-app and companion connections are refused: the app's cable carries no
# content (AppSyncChannel), and a companion device is not a person.
class TypingChannel < ApplicationCable::Channel

  STATES = %w[typing dictating idle].freeze
  # A browser sends at most one ping every few seconds; anything faster for the
  # same state is dropped here rather than fanned out.
  MIN_REPEAT_SECONDS = 1.5

  def self.stream_for_chat(chat)
    "Typing:#{chat.obfuscated_id}"
  end

  def subscribed
    return reject unless current_user
    return reject if current_app_session || current_companion_device

    @chat = Chat.find_by_obfuscated_id(params[:chat_id].to_s)
    return reject unless @chat && !@chat.discarded? && @chat.accessible_by?(current_user)

    stream_from self.class.stream_for_chat(@chat)
  end

  def typing(data)
    return unless @chat

    state = data["state"].to_s
    return unless STATES.include?(state)

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return if state == @last_state && state != "idle" && @last_sent_at && now - @last_sent_at < MIN_REPEAT_SECONDS

    @last_state = state
    @last_sent_at = now
    announce(state)
  end

  def unsubscribed
    announce("idle") if @chat && @last_state && @last_state != "idle"
    stop_all_streams
  end

  private

  def announce(state)
    ActionCable.server.broadcast(self.class.stream_for_chat(@chat), {
      user_id: current_user.obfuscated_id,
      name: current_user.first_name.presence || current_user.display_name,
      state: state
    })
  end

end
