require "test_helper"

class StoneHtmlRetentionTest < ActiveSupport::TestCase

  test "an old queued purge cannot destroy detached Stone source" do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("Retained original HTML"),
      filename: "stone.html", content_type: "text/html", metadata: { stone_html: true })
    assert_not blob.attachments.exists?
    ActiveStorage::PurgeJob.perform_now(blob)
    assert ActiveStorage::Blob.exists?(blob.id)
    assert_equal "Retained original HTML", blob.download
  end

  test "ordinary unattached uploads can still be purged" do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("Unsent upload"),
      filename: "note.txt", content_type: "text/plain")
    ActiveStorage::PurgeJob.perform_now(blob)
    assert_not ActiveStorage::Blob.exists?(blob.id)
  end

  test "string true is retained just like the delivery guard treats it" do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("Retained string-flagged HTML"),
      filename: "stone.html", content_type: "text/html", metadata: { stone_html: "true" })
    ActiveStorage::PurgeJob.perform_now(blob)
    assert ActiveStorage::Blob.exists?(blob.id)
    assert_equal "Retained string-flagged HTML", blob.download
  end

end
