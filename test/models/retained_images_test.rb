require "test_helper"

# Removed and replaced avatars and logos keep their bytes (#93).
class RetainedImagesTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper

  setup do
    @profile = users(:user_1).profile
  end

  test "replacing an avatar retains the old blob and its bytes survive the queued purge" do
    @profile.avatar.attach(png("first.png"))
    old_blob = @profile.avatar.blob

    perform_enqueued_jobs(only: ActiveStorage::PurgeJob) do
      @profile.update!(avatar: png("second.png"))
    end

    @profile.reload
    assert_equal "second.png", @profile.avatar.filename.to_s
    assert_equal [ old_blob.id ], @profile.retired_avatars.blobs.pluck(:id)
    assert ActiveStorage::Blob.exists?(old_blob.id)
    assert old_blob.service.exist?(old_blob.key)
  end

  test "retiring an avatar keeps the bytes, detaches it and skips owner validation" do
    @profile.avatar.attach(png("first.png"))
    blob = @profile.avatar.blob
    @profile.update_column(:first_name, nil)

    perform_enqueued_jobs { assert @profile.retire_avatar! }

    @profile.reload
    assert_not @profile.avatar.attached?
    assert_equal [ blob.id ], @profile.retired_avatars.blobs.pluck(:id)
    assert blob.service.exist?(blob.key)
  end

  test "retiring with no avatar is a no-op" do
    assert_not @profile.retire_avatar!
    assert_empty @profile.retired_avatars
  end

  test "saving the current avatar again adds no history row" do
    @profile.avatar.attach(png("first.png"))
    blob = @profile.avatar.blob

    perform_enqueued_jobs { @profile.update!(avatar: blob.signed_id) }

    @profile.reload
    assert_equal blob.id, @profile.avatar.blob.id
    assert_empty @profile.retired_avatars, "the live image is not history"
  end

  test "an older queued purge of a retained blob leaves it alone" do
    @profile.avatar.attach(png("first.png"))
    blob = @profile.avatar.blob
    @profile.retire_avatar!

    ActiveStorage::PurgeJob.perform_now(blob)

    assert ActiveStorage::Blob.exists?(blob.id)
    assert blob.service.exist?(blob.key)
  end

  test "restoring a retired avatar makes it current and retains the displaced one" do
    @profile.avatar.attach(png("first.png"))
    first = @profile.avatar.blob
    perform_enqueued_jobs { @profile.update!(avatar: png("second.png")) }
    second = @profile.reload.avatar.blob

    perform_enqueued_jobs { @profile.restore_retired_avatar!(first) }

    @profile.reload
    assert_equal first.id, @profile.avatar.blob.id
    assert_equal [ second.id ], @profile.retired_avatars.blobs.pluck(:id)
    assert [ first, second ].all? { |b| b.service.exist?(b.key) }, "restore keeps both images' bytes"
  end

  test "an avatar removed, restored and removed again keeps one history row and its bytes" do
    @profile.avatar.attach(png("first.png"))
    blob = @profile.avatar.blob
    perform_enqueued_jobs do
      @profile.retire_avatar!
      @profile.restore_retired_avatar!(blob)
      @profile.reload.retire_avatar!
    end

    @profile.reload
    assert_not @profile.avatar.attached?
    assert_equal [ blob.id ], @profile.retired_avatars.blobs.pluck(:id)
    assert blob.service.exist?(blob.key)
  end

  test "replacing and removing the site logo retains each one" do
    setting = Setting.instance
    setting.logo.attach(png("logo1.png"))
    first = setting.logo.blob
    setting.update!(logo: png("logo2.png"))
    second = setting.reload.logo.blob

    perform_enqueued_jobs { setting.retire_logo! }

    setting.reload
    assert_not setting.logo.attached?
    assert_equal [ first.id, second.id ].sort, setting.retired_logos.blobs.pluck(:id).sort
    assert [ first, second ].all? { |b| b.service.exist?(b.key) }
  end

  test "destroying the owner still erases its history" do
    @profile.avatar.attach(png("first.png"))
    blob = @profile.avatar.blob
    @profile.retire_avatar!

    perform_enqueued_jobs { @profile.destroy! }

    assert_not ActiveStorage::Blob.exists?(blob.id)
  end

  test "destroying the owner keeps the bytes of a history image attached elsewhere" do
    @profile.avatar.attach(png("first.png"))
    blob = @profile.avatar.blob
    chat = accounts(:personal_account).chats.create!(model_id: "openrouter/auto", title: "Shared")
    chat.messages.create!(content: "Same bytes", role: "user", user: users(:user_1)).attachments.attach(blob)
    @profile.retire_avatar!

    perform_enqueued_jobs { @profile.destroy! }

    assert ActiveStorage::Blob.exists?(blob.id)
    assert blob.service.exist?(blob.key)
  end

  private

  def png(name)
    { io: file_fixture("test_avatar.png").open, filename: name, content_type: "image/png" }
  end

end
