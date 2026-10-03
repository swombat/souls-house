require "test_helper"

class AttachmentDownloadsTest < ActiveSupport::TestCase

  test "uses request origin and download policy then restores storage context" do
    controller = Class.new do
      include AttachmentDownloads
      attr_accessor :request
    end.new
    controller.request = Struct.new(:protocol, :host, :optional_port).new("https://", "downloads.example.test", 8443)
    captured = {}
    blob = Object.new
    blob.define_singleton_method(:url) do |**options|
      captured[:options] = options
      captured[:origin] = ActiveStorage::Current.url_options
      "https://downloads.example.test/file"
    end
    attachment = Struct.new(:blob, :filename).new(blob, "example.pdf")

    ActiveStorage::Current.set(url_options: { host: "previous.example.test" }) do
      assert_equal "https://downloads.example.test/file", controller.send(:download_url_for, attachment)
      assert_equal({ host: "previous.example.test" }, ActiveStorage::Current.url_options)
    end
    assert_equal({ protocol: "https://", host: "downloads.example.test", port: 8443 }, captured[:origin])
    assert_equal({ expires_in: 5.minutes, disposition: :attachment, filename: "example.pdf" }, captured[:options])
  end

end
