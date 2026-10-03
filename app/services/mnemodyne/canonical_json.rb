module Mnemodyne::CanonicalJson

  def self.normalize(value)
    case value
    when Hash then value.stringify_keys.sort.to_h.transform_values { |child| normalize(child) }
    when Array then value.map { |child| normalize(child) }
    else value
    end
  end

end
