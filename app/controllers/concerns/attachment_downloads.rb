module AttachmentDownloads

  DOWNLOAD_URL_TTL = 5.minutes

  private

  def download_url_for(attachment)
    ActiveStorage::Current.set(
      url_options: {
        protocol: request.protocol,
        host: request.host,
        port: request.optional_port
      }
    ) do
      attachment.blob.url(
        expires_in: DOWNLOAD_URL_TTL,
        disposition: :attachment,
        filename: attachment.filename
      )
    end
  end

end
