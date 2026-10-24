module FieldVoiceSamples
  # Inspect the actual bytes, not the filename or claimed MIME type. No
  # conversion: the retained WAV is exactly what the embedding service hears.
  module Wav

    MAX_BYTES = 2 * 1024 * 1024
    module_function

    def read!(file)
      bytes = file.respond_to?(:read) ? file.read(MAX_BYTES + 1) : nil
      raise Invalid, "Choose a PCM mono 16-bit 16 kHz WAV, between 4 and 60 seconds." unless bytes.is_a?(String)

      bytes = bytes.b
      duration = duration!(bytes)
      [ bytes, duration ]
    end

    def duration!(bytes)
      refuse! unless bytes.bytesize.between?(44, MAX_BYTES) &&
        bytes.byteslice(0, 4) == "RIFF" && bytes.byteslice(8, 4) == "WAVE" &&
        bytes.byteslice(4, 4).unpack1("V") == bytes.bytesize - 8

      offset = 12
      format = nil
      data_size = nil
      while offset < bytes.bytesize
        refuse! if offset + 8 > bytes.bytesize
        kind = bytes.byteslice(offset, 4)
        size = bytes.byteslice(offset + 4, 4).unpack1("V")
        offset += 8
        refuse! if offset + size + (size.odd? ? 1 : 0) > bytes.bytesize
        case kind
        when "fmt "
          refuse! if format || size != 16
          format = bytes.byteslice(offset, size).unpack("vvVVvv")
        when "data"
          refuse! if data_size || !format
          data_size = size
        end
        offset += size + (size.odd? ? 1 : 0)
      end
      refuse! unless format == [ 1, 1, 16_000, 32_000, 2, 16 ] &&
        data_size && data_size.even? && data_size.between?(128_000, 1_920_000)

      data_size * 1_000 / 32_000
    end

    def refuse!
      raise Invalid, "Choose a PCM mono 16-bit 16 kHz WAV, between 4 and 60 seconds."
    end
    private_class_method :refuse!

  end
end
