module FeatureToggleable

  extend ActiveSupport::Concern

  class_methods do
    def require_feature_enabled(feature, **options)
      before_action(options) do
        unless Setting.feature_enabled?(feature)
          redirect_to root_path, alert: "This feature is currently disabled"
        end
      end
    end
  end

end
