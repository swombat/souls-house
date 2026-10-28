# The public data-model page (/data-model): the live schema, grouped by concern
# as config/data_model.yml names it. The schema is the source for tables, columns
# and foreign keys; the YAML only says which area a table belongs to and what the
# shape means. DataModelTest keeps the two in step: a table in the schema that the
# YAML does not name fails the suite, so the page cannot quietly go stale.
class DataModel

  PATH = Rails.root.join("config/data_model.yml")
  REPOSITORY_PATH = "https://github.com/swombat/souls-house/blob/master/config/data_model.yml"

  # Bump when the shape of area_json changes, so a durable cache does not serve
  # the old shape to new page code.
  PAYLOAD_VERSION = 2

  # Rails' own bookkeeping, never part of the application's model.
  FRAMEWORK_TABLES = %w[ar_internal_metadata schema_migrations].freeze

  Area = Struct.new(:id, :title, :summary, :table_names, keyword_init: true)

  class << self

    def areas
      YAML.safe_load_file(PATH).fetch("areas").map do |entry|
        Area.new(id: entry.fetch("id"), title: entry.fetch("title"), summary: entry.fetch("summary").strip,
          table_names: entry.fetch("tables").map(&:to_s))
      end
    end

    def find(id)
      areas.find { |area| area.id == id.to_s }
    end

    def schema_tables
      (connection.tables - FRAMEWORK_TABLES).sort
    end

    def mapped_tables
      areas.flat_map(&:table_names).uniq.sort
    end

    # Tables the schema has and the YAML does not name. Must be empty.
    def unmapped_tables
      schema_tables - mapped_tables
    end

    # Tables the YAML names that the schema no longer has. Must be empty.
    def unknown_tables
      mapped_tables - schema_tables
    end

    def areas_json
      areas.map { |area| { id: area.id, title: area.title, table_count: area.table_names.size } }
    end

    # One area for the page: its tables with columns and references, and a Mermaid
    # ER diagram of the keys between them. Cross-area references name the other
    # area so the page can link there. The cache is durable in production, so the
    # key carries everything the payload depends on: the schema version (a
    # migration), a digest of the whole map (prose, grouping and the cross-area
    # links that depend on other areas), and the payload version.
    def area_json(area)
      Rails.cache.fetch(cache_key(area), expires_in: 1.day) do
        build_area_json(area)
      end
    end

    def cache_key(area)
      [ "data_model", PAYLOAD_VERSION, schema_version, map_digest, area.id ]
    end

    private

    def connection
      ActiveRecord::Base.connection
    end

    def schema_version
      ActiveRecord::Base.connection_pool.migration_context.current_version
    end

    def map_digest
      Digest::SHA256.file(PATH).hexdigest.first(16)
    end

    def build_area_json(area)
      names = area.table_names
      tables = names.map { |name| table_json(name, area) }
      { id: area.id, title: area.title, summary: area.summary, tables: tables, diagram: diagram(area, tables) }
    end

    def table_json(name, area)
      {
        name: name,
        areas: area_ids_for(name),
        columns: connection.columns(name).map { |column| column_json(column) },
        references: foreign_keys_from(name).map { |key| reference_json(key, area) },
        referenced_by: foreign_keys_to(name).map do |key|
          { table: key.from_table, column: key_columns(key).join(", "), area: area_link(key.from_table, area) }
        end
      }
    end

    def column_json(column)
      type = (column.type || column.sql_type).to_s
      type = "#{type}[]" if column.respond_to?(:array) && column.array
      { name: column.name, type: type, null: column.null, primary_key: column.name == "id" }
    end

    def reference_json(key, area)
      { column: key_columns(key).join(", "), columns: key_columns(key), table: key.to_table,
        area: area_link(key.to_table, area), unique: unique_key?(key) }
    end

    # A composite key names several columns; most name one.
    def key_columns(key)
      Array(key.column).map(&:to_s)
    end

    # A foreign key whose columns are exactly a unique index is one-to-one: at
    # most one child row per parent. Anything else is many-to-one, including a
    # partial unique index (unique only among, say, unrevoked rows): that is a
    # rule about live rows, not about the table's shape.
    def unique_key?(key)
      columns = key_columns(key)
      unique_indexes(key.from_table).any? { |index| Array(index.columns).map(&:to_s) == columns }
    end

    def unique_indexes(table)
      @unique_indexes ||= {}
      @unique_indexes[[ schema_version, table ]] ||= connection.indexes(table).select do |index|
        index.unique && index.where.blank?
      end
    end

    # nil when the table is in the area being shown; otherwise the first other
    # area that holds it, for the link.
    def area_link(table, area)
      return nil if area.table_names.include?(table)

      other = areas.find { |candidate| candidate.table_names.include?(table) }
      other && { id: other.id, title: other.title }
    end

    def area_ids_for(table)
      areas.select { |area| area.table_names.include?(table) }.map(&:id)
    end

    def all_foreign_keys
      @all_foreign_keys ||= {}
      @all_foreign_keys[schema_version] ||= schema_tables.flat_map { |table| connection.foreign_keys(table) }
    end

    def foreign_keys_from(table)
      all_foreign_keys.select { |key| key.from_table == table }.sort_by { |key| key_columns(key) }
    end

    def foreign_keys_to(table)
      all_foreign_keys.select { |key| key.to_table == table }.sort_by { |key| [ key.from_table, *key_columns(key) ] }
    end

    # Mermaid erDiagram source. Entities carry their primary key and foreign-key
    # columns only; the full column list is in the table cards. A table outside
    # the area that one of its tables points at appears as a bare box. The child
    # end is zero-or-many, or zero-or-one when the key is unique; the parent end
    # is exactly one, or zero-or-one when the key column is nullable.
    def diagram(area, tables)
      lines = [ "erDiagram" ]
      tables.each do |table|
        key_columns = table[:columns].select do |column|
          column[:primary_key] || table[:references].any? { |reference| reference[:columns].include?(column[:name]) }
        end
        lines << "  #{table[:name]} {"
        key_columns.each do |column|
          marker = column[:primary_key] ? "PK" : "FK"
          lines << "    #{mermaid_word(column[:type])} #{column[:name]} #{marker}"
        end
        lines << "  }"
      end
      tables.each do |table|
        table[:references].each do |reference|
          optional = reference[:columns].any? do |name|
            table[:columns].find { |column| column[:name] == name }&.dig(:null)
          end
          label = reference[:columns].join("_")
          child = reference[:unique] ? "|o" : "}o"
          parent = optional ? "o|" : "||"
          lines << "  #{table[:name]} #{child}--#{parent} #{reference[:table]} : #{label}"
        end
      end
      lines.join("\n")
    end

    def mermaid_word(text)
      word = text.to_s.gsub(/[^A-Za-z0-9_]+/, "_").gsub(/\A_+|_+\z/, "")
      word.empty? ? "unknown" : word
    end

  end

end
