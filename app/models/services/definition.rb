module Services
  class Definition

    class UnknownProvider < KeyError; end

    attr_reader :key, :name, :management_scopes, :credential_strategy,
                 :api_origins, :documentation, :access_profiles,
                 :default_access_profile, :adapter_class, :connection_method,
                 :credential_fields, :runtime_notes, :authority_groups,
                 :base_scopes

    def self.register(**attributes)
      definition = new(**attributes)
      registry[definition.key] = definition
      definition
    end

    def self.fetch(key)
      ensure_catalog_loaded
      registry.fetch(key.to_s) { raise UnknownProvider, "Unknown service provider: #{key}" }
    end

    def self.all
      ensure_catalog_loaded
      registry.values
    end

    def self.registry
      @registry ||= {}
    end

    def self.ensure_catalog_loaded
      Services::Catalog
    end

    def initialize(key:, name:, management_scopes:, credential_strategy:, api_origins:,
                   documentation:, access_profiles: {}, default_access_profile: nil, adapter_class:,
                   connection_method: "oauth2", credential_fields: [], runtime_notes: [],
                   authority_groups: {}, base_scopes: [])
      @key = key.to_s
      @name = name
      @management_scopes = management_scopes.map(&:to_s).freeze
      @credential_strategy = credential_strategy.to_s
      @api_origins = api_origins.freeze
      @documentation = documentation.freeze
      @access_profiles = access_profiles.to_h.transform_keys(&:to_s).transform_values { |v| Array(v).map(&:to_s).freeze }.freeze
      @default_access_profile = default_access_profile&.to_s
      @authority_groups = normalize_authority_groups(authority_groups)
      @base_scopes = Array(base_scopes).map(&:to_s).freeze
      @adapter_class = adapter_class
      @connection_method = connection_method.to_s
      @credential_fields = credential_fields.map { |field| field.to_h.stringify_keys.freeze }.freeze
      @runtime_notes = Array(runtime_notes).map(&:to_s).freeze
    end

    def scopes_for(profile)
      access_profiles.fetch(profile.to_s)
    end

    def structured_authority?
      authority_groups.present?
    end

    def default_authority_selection
      authority_groups.to_h { |group, config| [ group, config.fetch("default") ] }
    end

    def normalize_authority_selection(selection)
      values = selection.to_h.stringify_keys
      unknown_groups = values.keys - authority_groups.keys
      raise ArgumentError, "Unsupported authority group: #{unknown_groups.first}" if unknown_groups.any?

      authority_groups.to_h do |group, config|
        option = values[group].presence || config.fetch("default")
        unless config.fetch("options").key?(option.to_s)
          raise ArgumentError, "Unsupported #{config.fetch('name')} authority: #{option}"
        end
        [ group, option.to_s ]
      end
    end

    def scopes_for_authority(selection)
      normalized = normalize_authority_selection(selection)
      scopes = normalized.flat_map do |group, option|
        authority_groups.fetch(group).fetch("options").fetch(option).fetch("scopes")
      end
      (base_scopes + scopes).uniq
    end

    def effective_authority(scopes, requested_selection:)
      if adapter.respond_to?(:effective_authority)
        adapter.effective_authority(scopes, requested_selection: requested_selection)
      else
        { "selection" => normalize_authority_selection(requested_selection), "warnings" => [] }
      end
    end

    def supports_management_scope?(scope)
      management_scopes.include?(scope.to_s)
    end

    def adapter
      adapter_class.constantize.new(self)
    end

    def as_json
      {
        key: key,
        name: name,
        management_scopes: management_scopes,
        connection_method: connection_method,
        credential_fields: credential_fields,
        credential_strategy: credential_strategy,
        authority_groups: authority_groups.map do |group, config|
          {
            key: group,
            name: config.fetch("name"),
            default: config.fetch("default"),
            parent: config["parent"],
            options: config.fetch("options").map do |option, option_config|
              {
                key: option,
                name: option_config.fetch("name"),
                rank: option_config.fetch("rank")
              }
            end
          }
        end,
        access_profiles: access_profiles.map do |profile, scopes|
          {
            key: profile,
            name: profile.humanize,
            scopes: scopes,
            default: profile == default_access_profile
          }
        end
      }
    end

    private

    def normalize_authority_groups(groups)
      groups.to_h.transform_keys(&:to_s).to_h do |group, config|
        normalized = config.to_h.stringify_keys
        options = normalized.fetch("options").to_h.transform_keys(&:to_s).to_h do |option, option_config|
          value = option_config.to_h.stringify_keys
          [
            option,
            {
              "name" => value.fetch("name"),
              "rank" => value.fetch("rank").to_i,
              "scopes" => Array(value["scopes"]).map(&:to_s).freeze
            }.freeze
          ]
        end.freeze
        [
          group,
          {
            "name" => normalized.fetch("name"),
            "default" => normalized.fetch("default").to_s,
            "parent" => normalized["parent"]&.to_s,
            "options" => options
          }.freeze
        ]
      end.freeze
    end

  end
end
