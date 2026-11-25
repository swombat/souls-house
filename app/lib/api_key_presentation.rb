class ApiKeyPresentation

  def initialize(key)
    @key = key
  end

  def as_json
    {
      id: @key.id,
      name: @key.name,
      prefix: @key.display_prefix,
      actor: actor,
      created_at: @key.created_at.strftime("%b %d, %Y"),
      last_used_at: @key.last_used_at&.strftime("%b %d, %Y at %l:%M %p"),
      last_used_ip: @key.last_used_ip
    }
  end

  private

  def actor
    if (agent = @key.agent)
      { type: "agent", id: agent.to_param, name: agent.name }
    else
      user = @key.user
      { type: "user", id: user.to_param, name: user.display_name }
    end
  end

end
