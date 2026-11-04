# The English voices of Gradium's Phonon catalogue (Apache-2.0), as served from
# /phonon-assets (config/phonon_assets.json). One list for the server, which
# checks a resident's choice, and the browser's picker, which imports the same
# file. Delia is the library's own default English voice.
module PhononVoices

  Voice = Struct.new(:id, :name, :locale, :gender, :age, :description, keyword_init: true)

  PATH = Rails.root.join("app/frontend/lib/phonon-voices.json")
  DEFAULT_NAME = "Delia"

  def self.catalogue
    @catalogue ||= JSON.parse(File.read(PATH)).map { |voice| Voice.new(**voice.symbolize_keys) }.freeze
  end

  def self.find(id)
    return nil if id.blank?

    catalogue.find { |voice| voice.id == id.to_s }
  end

  def self.standard?(id) = find(id).present?

  def self.default
    catalogue.find { |voice| voice.name == DEFAULT_NAME } || catalogue.first
  end

end
