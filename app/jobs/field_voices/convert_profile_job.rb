module FieldVoices
  class ConvertProfileJob < ApplicationJob

    queue_as :default
    retry_on FieldVoiceprints::VoiceEmbeddings::Unavailable, wait: :polynomially_longer, attempts: 6

    def perform(account_id)
      account = Account.find_by(id: account_id)
      FieldVoiceprints::Conversion.run!(account) if account
    end

  end
end
