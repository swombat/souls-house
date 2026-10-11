# Field OCR in tests: turned on for the test, with a fake model that records
# what it was sent. Nothing leaves the machine.
module FieldOcrHelpers

  # Stands in for UtilityInference.house_vision.
  class FakeVision

    attr_reader :calls

    def initialize(answers = nil, &block)
      @answers = answers
      @block = block
      @calls = []
    end

    def house_vision(**params)
      @calls << params
      answer = @block ? @block.call(params, @calls.size) : Array(@answers)[@calls.size - 1] || "Transcribed text."
      raise answer if answer.is_a?(Exception)

      { text: answer, usage: { "cost" => 0.0008 }, id: "gen-#{@calls.size}", finish_reason: "stop" }
    end

  end

  # Test credentials may carry no house key; the fake model needs none.
  def enable_field_ocr(ceiling: 1)
    FieldOcr.live = true
    @configured_was ||= HouseInference::Offering.method(:configured?)
    HouseInference::Offering.define_singleton_method(:configured?) { true }
    Setting.instance.update!(field_ocr_enabled: true, field_ocr_daily_usd_ceiling: ceiling)
  end

  def disable_field_ocr
    FieldOcr.live = false
    HouseInference::Offering.define_singleton_method(:configured?, @configured_was) if @configured_was
  end

  def field_pdf(account, name, user: nil)
    account.field_files.create!(uploaded_by: user,
      file: Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/field_pdfs", name), "application/pdf"))
  end

  # [width, height] from a PNG's IHDR chunk.
  def png_size(bytes)
    bytes.byteslice(16, 8).unpack("NN")
  end

end
