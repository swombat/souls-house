class DirectReplyMentions

  # The people a message tags directly (ReplyAttention).
  def self.call(message:, users:)
    new(message: message, users: users).tagged(:user)
  end

  # The residents of the message's room it tags directly: a resident's
  # handoff (MessageHandoff). The same reading as for people, so a tag inside
  # a quote, code, a link or an escaped @ asks no one. One difference: when a
  # person and a resident share the tagged name, the resident wins, because
  # only a resident can be woken by a handoff (Daniel, EJRGmY: a resident can
  # also have a person's login in the same account). Two residents sharing it
  # still tags neither.
  def self.agent_ids(message:, users:)
    agent_tags(message: message, users: users).ids
  end

  AgentTags = Struct.new(:ids, :ambiguous_ids, keyword_init: true)

  # agent_ids, plus the residents a tag could not pick between: each entry is
  # the ids of two or more residents in the room who share the tagged name,
  # so the room can be told the tag woke no one.
  def self.agent_tags(message:, users:)
    reader = new(message: message, users: users)
    ids = reader.tagged(:agent)
    AgentTags.new(ids: ids, ambiguous_ids: reader.ambiguous_agent_ids)
  end

  def initialize(message:, users:)
    @message = message
    @users = users
    @ambiguous_agent_ids = []
  end

  attr_reader :ambiguous_agent_ids

  def tagged(kind)
    return [] unless @message.content.to_s.include?("@")

    aliases = Hash.new { |hash, name| hash[name] = [] }
    @users.each do |user|
      add_aliases(aliases, [ user.full_name, user.first_name ], [ :user, user.id ])
    end
    @message.chat.agents.each do |agent|
      add_aliases(aliases, [ agent.name, agent.name.to_s.split.first ], [ :agent, agent.id ])
    end
    return [] if aliases.empty?

    # Include ambiguous aliases in the pattern: a longer ambiguous name must
    # never fall back to an unambiguous first name.
    names = aliases.keys.sort_by { |name| [ -name.length, name ] }
    pattern = Regexp.new(
      "(?<![\\p{L}\\p{M}\\p{N}_@])@(#{names.map { |name| Regexp.escape(name) }.join("|")})" \
      "(?![\\p{L}\\p{M}\\p{N}_@]|[.\\-'’][\\p{L}\\p{M}\\p{N}_])"
    )
    ids = visible_text.scan(pattern).filter_map do |match|
      owners = aliases.fetch(match.first).uniq
      id = owner_for(owners, kind)
      next unless id

      id unless id == (kind == :user ? @message.user_id : @message.agent_id)
    end
    ids.uniq
  end

  private

  # A person's tag needs the name to be unique among people and residents.
  # A resident's handoff only needs it unique among residents.
  def owner_for(owners, kind)
    if kind == :agent
      agents = owners.select { |owner| owner.first == :agent }.map(&:last).uniq
      @ambiguous_agent_ids |= [ agents.sort ] if agents.many?
      agents.first if agents.one?
    elsif owners.one? && owners.first.first == kind
      owners.first.last
    end
  end

  def add_aliases(aliases, names, owner)
    names.each do |name|
      normalized = normalize(name.to_s.strip)
      next if normalized.empty? || normalized.include?("@")

      aliases[normalized] << owner
    end
  end

  def normalize(text)
    text.unicode_normalize(:nfc).downcase(:fold)
  end

  def visible_text
    # Markdown removes the escape before rendering. Neutralize escaped at signs
    # first, respecting even/odd runs of backslashes.
    source = @message.content.to_s.gsub(/(\\+)@/) do
      slashes = Regexp.last_match(1)
      slashes.length.odd? ? "#{slashes} " : "#{slashes}@"
    end
    renderer = Redcarpet::Markdown.new(
      # This fragment is never served. Render every link as an anchor so even
      # rejected/unsafe destinations have their labels removed below.
      Redcarpet::Render::HTML.new(filter_html: true, hard_wrap: true),
      autolink: true, no_intra_emphasis: true, fenced_code_blocks: true,
      tables: true, strikethrough: true
    )
    document = Nokogiri::HTML.fragment(renderer.render(source))
    document.css("blockquote, pre, code, a, img").each { |node| node.replace("\n") }
    document.css("br").each { |node| node.replace("\n") }
    text = document.text.gsub(%r{(?:https?://|www\.)\S+}i, "\n")
    normalize(text)
  end

end
