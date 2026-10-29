# Streams a text attachment (markdown, plain text, CSV, JSON...) for the
# in-conversation preview. It is ActiveStorage's proxy, same origin so the
# browser can read the bytes without storage CORS, with one difference: the
# stock proxy marks every full response public and cacheable forever, so a
# browser or shared cache could keep serving a file after its message was
# deleted without ever asking us. Previews are private and never stored.
#
# The blob lookup is the proxy's own, so HidesDiscardedBlobs and
# HidesStoneBlobs (prepended to the proxy in active_storage_discard.rb) apply
# here too: a deleted message's preview is a 404, as its download is.
class AttachmentPreviewsController < ActiveStorage::Blobs::ProxyController

  def show
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["Content-Length"] = @blob.byte_size.to_s
    send_blob_stream @blob, disposition: :inline
  end

end
