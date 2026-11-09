# Current titles for the conversation IDs written in a chat's messages, so
# they can render as links (ConversationRef on the frontend). Only
# conversations the reader could open answer: the same scope the chat page
# uses (current_account.chats.kept). Another account's conversation, or a
# discarded one, is simply absent, so its title never leaves the server.
class Accounts::ConversationTitlesController < ApplicationController

  MAX_IDS = 50
  ID_FORMAT = /\A[A-Za-z]{6}\z/

  # GET /accounts/:account_id/conversation_titles?ids=eqRAMj,YZxGbj
  def index
    render json: { titles: titles_for(requested_ids) }
  end

  private

  def requested_ids
    params[:ids].to_s.split(",").map(&:strip).grep(ID_FORMAT).uniq.first(MAX_IDS)
  end

  def titles_for(ids)
    decoded = ids.filter_map do |public_id|
      id = decode(public_id)
      [ public_id, id ] if id
    end.to_h
    return {} if decoded.empty?

    chats = current_account.chats.kept.where(id: decoded.values).index_by(&:id)
    decoded.filter_map do |public_id, id|
      chat = chats[id]
      [ public_id, chat.title_or_default ] if chat
    end.to_h
  end

  # Only an ID that encodes back to itself is a conversation's public ID; any
  # other six letters (a word, another model's ID) never reaches the query.
  def decode(public_id)
    id = Chat.hashids.decode(public_id).first
    id if id.is_a?(Integer) && Chat.encode_id(id) == public_id
  rescue Hashids::InputError
    nil
  end

end
