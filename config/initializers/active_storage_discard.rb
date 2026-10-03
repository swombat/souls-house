Rails.application.config.to_prepare do
  ActiveStorage::DiskController.prepend(HidesStoneDiskFiles)
  [
    ActiveStorage::Blobs::RedirectController,
    ActiveStorage::Blobs::ProxyController,
    ActiveStorage::Representations::RedirectController,
    ActiveStorage::Representations::ProxyController
  ].each do |controller|
    controller.prepend(HidesDiscardedMessageBlobs)
    controller.prepend(HidesStoneBlobs)
  end
end
