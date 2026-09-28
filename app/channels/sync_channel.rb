class SyncChannel < ApplicationCable::Channel

  ALLOWED_MODELS = {
    "Account" => {
      model: Account,
      collections: %w[agents chats whiteboards],
      allow_all: true
    },
    "Agent" => {
      model: Agent,
      collections: []
    },
    "Chat" => {
      model: Chat,
      collections: %w[messages]
    },
    "Whiteboard" => {
      model: Whiteboard,
      collections: []
    },
    "Setting" => {
      allow_all: true
    }
  }.freeze

  def subscribed
    debug "📡 Attempting to subscribe to #{params[:model]}:#{params[:id]}"

    # Native-app connections subscribe to AppSyncChannel, whose broadcasts
    # carry no content; the web's streams do.
    return reject_for_reason("app connections use AppSyncChannel") if current_app_session

    model_name = params[:model].to_s
    return reject_for_reason("params[:model] is not present") if model_name.blank?
    return reject_for_reason("params[:id] is not present") unless params[:id].present?

    model_config = ALLOWED_MODELS[model_name]
    return reject_for_reason("model is not allowed") unless model_config

    if params[:id] == "all"
      return reject_for_reason("model does not support all subscriptions") unless model_config[:allow_all]
      return reject_for_reason("current_user.site_admin is false") unless current_user.site_admin

      stream_from "#{model_name}:all"
      return
    end

    return reject_for_reason("model does not support direct subscriptions") unless model_config[:model]

    record_id, collection_name = params[:id].split(":", 2)
    @model = model_config[:model].find_by_obfuscated_id(record_id)
    return reject_for_reason("model is not present") unless @model

    return reject_for_reason("model is not accessible by current_user") unless @model.accessible_by?(current_user)

    if collection_name
      setup_collection_subscription(model_name, model_config, collection_name)
    else
      stream_from "#{model_name}:#{@model.obfuscated_id}"
    end
  end

  def setup_collection_subscription(model_name, model_config, collection_name)
    allowed_collections = model_config.fetch(:collections, [])
    return reject_for_reason("collection is not allowed") unless allowed_collections.include?(collection_name)

    collection = @model.public_send(collection_name)
    return reject_for_reason("collection is not present") unless collection.respond_to?(:each)

    debug "📡 Streaming #{model_name}:#{@model.obfuscated_id}:#{collection_name}"

    Array(collection).each do |record|
      next unless record.respond_to?(:obfuscated_id)
      next unless record.accessible_by?(current_user)

      stream_from "#{record.class.name}:#{record.obfuscated_id}"
    end
  end

  def reject_for_reason(reason)
    debug "📡 ❌ Rejecting subscription for #{params[:model]}:#{params[:id]} because #{reason}"
    reject
  end

  def stream_from(identifier)
    debug "📡 ✅ Streaming #{identifier}"
    super(identifier)
  end

  def unsubscribed
    debug "📡 ❌ Unsubscribed from all"
    stop_all_streams
  end

end
