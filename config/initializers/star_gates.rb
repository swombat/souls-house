Rails.application.config.to_prepare do
  StarGates.flags.configuration = -> { Setting.feature_flags }
end
