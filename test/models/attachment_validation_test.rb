require "test_helper"

class AttachmentValidationTest < ActiveSupport::TestCase

  ATTACHMENTS = [
    [ Profile, :avatar, "PNG, JPG, GIF, WEBP" ],
    [ Setting, :logo, "PNG, JPG, GIF, WEBP, SVG" ]
  ].freeze

  test "avatar and logo are optional" do
    ATTACHMENTS.each do |model, _attribute, _types|
      record = build_record(model)
      assert record.valid?, record.errors.full_messages.join(", ")
    end
  end

  test "avatar and logo accept every configured raster MIME type" do
    ATTACHMENTS.each do |model, attribute, _types|
      { "png" => "image/png", "jpg" => "image/jpeg", "gif" => "image/gif", "webp" => "image/webp" }.each do |extension, content_type|
        record = attached_record(model, attribute, filename: "image.#{extension}", content_type: content_type)

        assert record.valid?, "#{model} #{content_type}: #{record.errors.full_messages}"
      end
    end
  end

  test "SVG remains allowed for logos but not avatars" do
    profile = attached_record(Profile, :avatar, filename: "image.svg", content_type: "image/svg+xml")
    assert_not profile.valid?
    assert_equal [ :content_type_invalid ], profile.errors.details[:avatar].map { |error| error[:error] }

    setting = attached_record(Setting, :logo, filename: "image.svg", content_type: "image/svg+xml")
    assert setting.valid?, setting.errors.full_messages.join(", ")
  end

  test "disallowed MIME types retain attachment error keys and messages" do
    I18n.with_locale(:en) do
      ATTACHMENTS.each do |model, attribute, types|
        { "notes.txt" => "text/plain", "document.pdf" => "application/pdf" }.each do |filename, content_type|
          record = attached_record(model, attribute, filename: filename, content_type: content_type)

          assert_not record.valid?
          assert_equal [ attribute ], record.errors.attribute_names
          assert_equal [ :content_type_invalid ], record.errors.details[attribute].map { |error| error[:error] }
          assert_equal [ "has an invalid content type (authorized content types are #{types})" ], record.errors[attribute]
          assert_equal content_type, record.errors.details[attribute].first[:content_type]
          assert_equal filename, record.errors.details[attribute].first[:filename]
        end
      end
    end
  end

  test "avatar and logo enforce a strictly less than five MiB size limit" do
    I18n.with_locale(:en) do
      ATTACHMENTS.each do |model, attribute, _types|
        record = attached_record(model, attribute, byte_size: 5.megabytes - 1)
        assert record.valid?, record.errors.full_messages.join(", ")

        [ 5.megabytes, 5.megabytes + 1 ].each do |byte_size|
          record = attached_record(model, attribute, byte_size: byte_size)

          assert_not record.valid?, "#{model} accepted #{byte_size} bytes"
          assert_equal [ attribute ], record.errors.attribute_names
          assert_equal [ :file_size_not_less_than ], record.errors.details[attribute].map { |error| error[:error] }
          assert_equal [ "file size must be less than 5 MB (current size is 5 MB)" ], record.errors[attribute]
        end
      end
    end
  end

  test "shared content type validator keeps concurrent PNG and text checks separate" do
    valid = attached_record(Profile, :avatar)
    invalid = attached_record(Profile, :avatar, filename: "notes.txt", content_type: "text/plain")
    validator = Profile.validators_on(:avatar).find { |candidate| candidate.is_a?(ActiveStorageValidations::ContentTypeValidator) }
    entered, release = Queue.new, Queue.new
    paused = false

    # Pause after the validator reads the invalid blob's content type, before
    # it finishes reading its filename. Only scheduling is controlled: both
    # blobs, attachment associations and MIME decisions remain real.
    invalid.avatar.blob.define_singleton_method(:filename) do
      unless paused
        paused = true
        entered << true
        release.pop
      end
      super()
    end

    # Use the same model-owned validator without unrelated validations or
    # cross-thread database access. All records/associations are built above.
    worker = Thread.new { validator.validate(invalid) }
    assert entered.pop(timeout: 5), "invalid validation did not reach filename"
    validator.validate(valid)
    assert_empty valid.errors
    release << true
    assert worker.join(5), "invalid validation did not finish"
    worker.value

    assert_equal [ :content_type_invalid ], invalid.errors.details[:avatar].map { |error| error[:error] }
    assert_equal "text/plain", invalid.errors.details[:avatar].first[:content_type]
    assert_equal "notes.txt", invalid.errors.details[:avatar].first[:filename]
  ensure
    release << true if release
    worker.kill if worker&.alive?
    worker&.join
  end

  private

  def build_record(model)
    if model == Profile
      Profile.new(user: users(:user_1), first_name: "Test", last_name: "User")
    else
      Setting.new
    end
  end

  def attached_record(model, attribute, filename: "image.png", content_type: "image/png", byte_size: 1)
    record = build_record(model)
    # These validators inspect declared MIME/size only (no spoofing or media
    # analysis). An identified, unsaved blob avoids uploads and giant files.
    blob = ActiveStorage::Blob.new(filename: filename, content_type: content_type,
      byte_size: byte_size, metadata: { identified: true })
    record.public_send("#{attribute}=", blob)
    record.public_send(attribute).attachment
    record
  end

end
