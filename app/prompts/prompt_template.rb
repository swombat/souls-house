# frozen_string_literal: true

# Prompts the house sends on its own behalf live as files, so a person can read
# and tune one without reading Ruby: app/prompts/<name>/<part>.prompt.erb.
# This only renders text. Sending it is UtilityInference's job.
#
#   PromptTemplate.render("generate_title", :user, messages: lines)
#
# Locals are interpolated with plain ERB (no HTML escaping). Interpolated
# values are never evaluated as ERB themselves.
module PromptTemplate

  class Missing < StandardError; end

  def self.render(name, part, **locals)
    path = Rails.root.join("app", "prompts", name.to_s, "#{part}.prompt.erb")
    raise Missing, "No prompt template at #{path.relative_path_from(Rails.root)}" unless path.file?

    ERB.new(path.read).result_with_hash(locals)
  end

end
