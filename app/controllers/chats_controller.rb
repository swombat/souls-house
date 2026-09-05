class ChatsController < ApplicationController

  require_feature_enabled :chats
  before_action :set_chat, except: [ :index, :create, :new, :search ]
  before_action :require_available_agents, only: [ :index, :new ]

  def index
    @chats = sidebar_chats

    render inertia: "chats/new", props: {
      chats: Chat.cached_json_for(Array(@chats), as: :sidebar_json),
      agents: available_agents(as: :list),
      account: current_account.as_json,
      show_usage_in_chat: Setting.instance.show_usage_in_chat,
      file_upload_config: file_upload_config
    }
  end

  def new
    @chats = sidebar_chats

    render inertia: "chats/new", props: {
      chats: Chat.cached_json_for(@chats, as: :sidebar_json),
      account: current_account.as_json,
      agents: available_agents(as: :list),
      show_usage_in_chat: Setting.instance.show_usage_in_chat,
      file_upload_config: file_upload_config
    }
  end

  def show
    props = {
      account: current_account.as_json,
      show_usage_in_chat: Setting.instance.show_usage_in_chat
    }

    if inertia_prop_requested?(:chats)
      chats = sidebar_chats
      props[:chats] = Chat.cached_json_for(chats, as: :sidebar_json)
    end

    if inertia_prop_requested?(:messages)
      messages = @chat.messages_page
      has_more = messages.any? && @chat.messages.where("id < ?", messages.first.id).exists?
      interaction_costs = InteractionCostsByMessage.new(chat: @chat, messages: messages).call
      props[:messages] = messages.map { |message| message_json(message, interaction_costs[message.id]) }
      props[:has_more_messages] = has_more
      props[:oldest_message_id] = messages.first&.to_param
    end

    props[:runtime_interactions] = runtime_interactions_for_timeline if inertia_prop_requested?(:runtime_interactions)
    props[:cost_breakdown] = ChatUsageReport.new(chat: @chat).call if inertia_prop_requested?(:cost_breakdown)

    props[:chat] = chat_json_with_whiteboard if inertia_prop_requested?(:chat)
    props[:models] = available_models if inertia_prop_requested?(:models)
    props[:agents] = @chat.group_chat? ? agents_json(@chat.agents, as: :list) : [] if inertia_prop_requested?(:agents)
    props[:available_agents] = available_agents(as: :list) if inertia_prop_requested?(:available_agents)
    props[:addable_agents] = addable_agents_for_chat(as: :list) if inertia_prop_requested?(:addable_agents)
    props[:file_upload_config] = file_upload_config if inertia_prop_requested?(:file_upload_config)
    props[:telegram_deep_link] = telegram_deep_link_for_chat if inertia_prop_requested?(:telegram_deep_link)

    render inertia: "chats/show", props: props
  end

  def create
    unless available_agents_scope.exists?
      redirect_to agent_creation_path, alert: "Create an agent before starting a conversation"
      return
    end

    agents = selected_agents
    if agents.empty?
      redirect_to new_account_chat_path(current_account), alert: "Select at least one agent"
      return
    end

    @chat = current_account.chats.create_with_message!(
      chat_create_params.merge(manual_responses: true),
      message_content: params[:message],
      user: Current.user,
      files: params[:files],
      agent_ids: agents.map(&:id)
    )
    audit("create_chat", @chat, **chat_create_params.to_h)
    redirect_to account_chat_path(current_account, @chat)
  rescue ActiveRecord::RecordNotFound
    redirect_to new_account_chat_path(current_account), alert: "Select valid agents from this account"
  end

  def update
    @chat = current_account.chats.find(params[:id])

    if @chat.update(chat_params)
      redirect_to account_chat_path(current_account, @chat)
    else
      redirect_back_or_to account_chat_path(current_account, @chat), alert: @chat.errors.full_messages.to_sentence
    end
  end

  def destroy
    audit("destroy_chat", @chat)
    @chat.destroy!
    redirect_to account_chats_path(current_account)
  end

  def search
    @query = params[:q].to_s.strip.first(500)

    if @query.present?
      @pagy, @messages = pagy(:offset, Message.search_in_account(current_account, @query), limit: 20)
    end

    render inertia: "chats/search", props: {
      query: @query,
      results: (@messages || []).map { |m| search_result_json(m, @query) },
      pagination: pagy_to_hash(@pagy)
    }
  end

  private

  def sidebar_chats
    base_scope = current_account.chats

    if params[:show_deleted].present? && can_manage_account?
      chats = base_scope.with_discarded
    else
      chats = base_scope.kept
    end

    # Filter out agent-only chats unless site admin has toggled them on
    unless params[:show_agent_only].present? && Current.user&.site_admin
      chats = chats.not_agent_only
    end

    if params[:show_deleted].present? && can_manage_account?
      chats.latest
    else
      chats.active.latest + chats.archived.latest
    end
  end

  def set_chat
    # Use with_discarded to allow admins to find discarded chats for restore
    @chat = current_account.chats.with_discarded.find(params[:id])
  end

  def chat_params
    params.fetch(:chat, {})
      .permit(:model_id, :web_access, :manual_responses, :title)
  end

  def chat_create_params
    params.fetch(:chat, {}).permit(:title)
  end

  def available_models
    @available_models ||= Chat::MODELS
  end

  def file_upload_config
    {
      acceptable_types: Message::ACCEPTABLE_FILE_TYPES.values.flatten,
      acceptable_extensions: Message::ACCEPTABLE_EXTENSIONS,
      max_size: Message::MAX_FILE_SIZE
    }
  end

  def available_agents(as: nil)
    agents_json(available_agents_scope, as: as)
  end

  def available_agents_scope
    current_account.agents.eligible_for_conversation.order(:paused, :name)
  end

  def selected_agents
    ids = Array(params[:agent_ids]).reject(&:blank?)
    return [] if ids.empty?

    current_account.agents.eligible_for_conversation.find(Agent.decode_id(ids))
  end

  def require_available_agents
    return if available_agents_scope.exists?

    redirect_to agent_creation_path, alert: "Create an agent before starting a conversation"
  end

  def agent_creation_path
    account_agents_path(current_account, create: true)
  end

  def addable_agents_for_chat(as: nil)
    return [] unless @chat.group_chat?
    scope = current_account.agents.eligible_for_conversation.where.not(id: @chat.agent_ids)
    agents_json(scope, as: as)
  end

  def agents_json(agents, as: nil)
    agents.map do |agent|
      json = as.present? ? agent.as_json(as: as) : agent.as_json
      subscription = Agents::ProviderSubscriptionPresentation.call(agent)
      subscription ? json.merge("provider_subscription" => subscription) : json
    end
  end

  def runtime_interactions_for_timeline
    @chat.agent_runtime_interactions
      .includes(:agent)
      .recent
      .limit(20)
      .select(&:visible_in_chat_timeline?)
      .sort_by { |interaction| interaction.finished_at || interaction.started_at || interaction.created_at }
      .map(&:as_chat_activity_json)
  end

  def message_json(message, interaction_cost = nil)
    message.as_json(include_ruby_llm_telemetry: Current.user&.site_admin).tap do |json|
      json["interaction_cost"] = interaction_cost if interaction_cost
    end
  end

  def chat_json_with_whiteboard
    json = @chat.as_json
    if @chat.active_whiteboard && !@chat.active_whiteboard.deleted?
      json[:active_whiteboard] = {
        id: @chat.active_whiteboard.id,
        name: @chat.active_whiteboard.name,
        content: @chat.active_whiteboard.content,
        revision: @chat.active_whiteboard.revision,
        last_edited_at: @chat.active_whiteboard.last_edited_at&.strftime("%b %d at %l:%M %p"),
        editor_name: @chat.active_whiteboard.editor_name
      }
    end
    json
  end

  def telegram_deep_link_for_chat
    telegram_agent = @chat.agents.detect(&:telegram_configured?)
    return nil unless telegram_agent

    existing_sub = telegram_agent.telegram_subscriptions.find_by(user: Current.user, blocked: false)
    return nil if existing_sub

    telegram_agent.telegram_deep_link_for(Current.user)
  end

  def can_manage_account?
    current_account.manageable_by?(Current.user)
  end

  def inertia_partial_request?
    request.headers["X-Inertia-Partial-Component"].present?
  end

  def inertia_partial_props
    @inertia_partial_props ||= (request.headers["X-Inertia-Partial-Data"] || "").split(",").map(&:strip)
  end

  def inertia_prop_requested?(prop)
    return true unless inertia_partial_request?
    return true if inertia_partial_props.empty?

    inertia_partial_props.include?(prop.to_s)
  end

  def search_result_json(message, query)
    {
      id: message.to_param,
      chat_id: message.chat.to_param,
      chat_title: message.chat.title_or_default,
      snippet: snippet_around(message.content, query),
      author_name: message.author_name,
      role: message.role,
      created_at: message.created_at.strftime("%b %-d, %Y at %-l:%M %p")
    }
  end

  def snippet_around(content, query)
    return content.to_s.truncate(200) if content.blank? || query.blank?

    lines = content.lines
    match_index = lines.index { |line| line.downcase.include?(query.downcase) }
    return content.truncate(200) unless match_index

    start = [ match_index - 1, 0 ].max
    finish = [ match_index + 1, lines.length - 1 ].min
    lines[start..finish].map(&:strip).join("\n").truncate(300)
  end

end
