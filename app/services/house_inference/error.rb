module HouseInference
  class Error < StandardError

    attr_reader :code, :status
    def initialize(message, code: 'house_inference_unavailable', status: 503)
      super(message)
      @code, @status = code, status
    end

  end
end
