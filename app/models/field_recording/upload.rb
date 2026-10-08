# Direct uploads for recordings (spec §4). The Field never accepts a bare
# signed blob id, because that would let someone attach a blob they once had a
# URL for. Instead the blob is created here with a pin in its metadata, signed
# by the server so a client can't forge one through the generic direct-upload
# endpoint, naming the user and account it was made for. Claiming checks the
# pin and attaches under the blob's row lock, so two claims (or a claim and the
# orphan purge) can't both win.
module FieldRecording::Upload

  METADATA_KEY = "field_recording_upload"
  TTL = 6.hours
  CONTENT_TYPE = %r{\A(audio|video)/[\w.+-]+\z}
  CHECKSUM = %r{\A[A-Za-z0-9+/]{22}==\z}

  module_function

  def create_blob!(account:, user:, filename:, content_type:, byte_size:, checksum:)
    ActiveStorage::Blob.create_before_direct_upload!(
      filename:, content_type:, byte_size:, checksum:,
      metadata: { METADATA_KEY => pin_for(account:, user:) }
    )
  end

  def valid_declaration?(filename:, content_type:, byte_size:, checksum:)
    filename.is_a?(String) && filename.present? && filename.length <= 255 &&
      content_type.is_a?(String) && content_type.match?(CONTENT_TYPE) &&
      checksum.is_a?(String) && checksum.match?(CHECKSUM) &&
      byte_size.is_a?(Integer) && byte_size.between?(1, FieldRecording::MAX_BYTES)
  end

  # Returns the new recording, or nil when the upload can't be used (wrong
  # owner, expired, already attached, never a recording upload). The caller
  # says nothing more specific about the blob.
  def claim!(account:, user:, signed_id:, attributes:)
    found = ActiveStorage::Blob.find_signed(signed_id.to_s)
    return nil unless found

    ActiveStorage::Blob.transaction do
      blob = ActiveStorage::Blob.lock.find_by(id: found.id)
      next nil unless blob && pinned_to?(blob, account:, user:)
      next nil if ActiveStorage::Attachment.exists?(blob_id: blob.id)

      account.field_recordings.create!(attributes.merge(uploaded_by: user, audio: blob))
    end
  end

  def pinned_to?(blob, account:, user:)
    pin = verifier.verified(blob.metadata[METADATA_KEY].to_s)
    pin.is_a?(Hash) && pin["account_id"] == account.id && pin["user_id"] == user.id
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    false
  end

  def recording_upload?(blob)
    blob.metadata.key?(METADATA_KEY)
  end

  def pin_for(account:, user:)
    verifier.generate({ "account_id" => account.id, "user_id" => user.id }, expires_in: TTL)
  end

  def verifier
    Rails.application.message_verifier("field-recording-upload")
  end

end
