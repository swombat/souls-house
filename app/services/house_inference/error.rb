module HouseInference
  class Error < StandardError

    # reason: the sanitised upstream refusal (HouseInference::RefusalReason),
    # for the run record only; never sent back to the resident.
    attr_reader :code, :status, :reason
    def initialize(message, code: 'house_inference_unavailable', status: 503, reason: nil)
      super(message)
      @code, @status, @reason = code, status, reason
    end

  end
end
