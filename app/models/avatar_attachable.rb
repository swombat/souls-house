# What an avatar form sends, turned into something Active Storage can attach:
# an uploaded file as is, or a pasted web address fetched by RemoteImageFetch.
# Only a real multipart file is accepted as a file; a string there would reach
# Active Storage as a signed blob id and a hash as attachable attributes.
module AvatarAttachable

  class Error < StandardError; end

  def self.from(file:, url:, fetcher: RemoteImageFetch)
    return file if file.is_a?(ActionDispatch::Http::UploadedFile)
    raise Error, "Avatar must be an uploaded image file" if file.present?
    raise Error, "Choose a picture, drop one here, or paste its web address" if url.blank?

    image = fetcher.call(url.to_s)
    { io: image.io, filename: image.filename, content_type: image.content_type }
  end

end
