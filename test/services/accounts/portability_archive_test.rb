require "test_helper"
require "zip"

# The account archive is hostile input: every refusal happens before
# anything persistent exists.
class Accounts::PortabilityArchiveTest < ActiveSupport::TestCase

  setup do
    @account = Account.create!(name: "Synthetic #{SecureRandom.hex(3)}", account_type: "team")
    @user = users(:user_1)
    @account.memberships.create!(user: @user, role: "owner", confirmed_at: Time.current)
    @account.whiteboards.create!(name: "Note", content: "synthetic")
    @members = nil
    Accounts::Portability::Export.call(@account, exporter: @user) do |path, _manifest|
      @members = {}
      Zip::File.open(path) { |zip| zip.each { |e| @members[e.name] = e.get_input_stream.read } }
    end
  end

  def zip_of(members, symlink: nil)
    buffer = Zip::OutputStream.write_buffer do |out|
      members.each do |name, body|
        out.put_next_entry(name)
        out.write(body)
      end
      if symlink
        entry = Zip::Entry.new("", symlink)
        entry.instance_variable_set(:@ftype, :symlink)
        entry.external_file_attributes = (0o120777 << 16)
        out.put_next_entry(entry)
        out.write("/etc/passwd")
      end
    end
    StringIO.new(buffer.string)
  end

  def manifest = JSON.parse(@members["manifest.json"])

  def with_manifest(changes)
    m = manifest.merge(changes)
    @members.merge("manifest.json" => JSON.generate(m))
  end

  # Adds a member and keeps the inventory honest, so a later check is the one reached.
  def with_member(name, body)
    m = manifest
    m["inventory"][name] = { "size" => body.bytesize, "sha256" => Digest::SHA256.hexdigest(body) }
    @members.merge(name => body, "manifest.json" => JSON.generate(m))
  end

  def refused(io, pattern)
    error = assert_raises(Accounts::Portability::Error) { Accounts::Portability::Archive.with_file(io) { flunk "must not yield" } }
    assert_match pattern, error.message
  end

  test "our own export validates and previews" do
    Accounts::Portability::Archive.with_file(zip_of(@members)) do |archive|
      assert_equal 1, archive.preview[:field]["notes"]
      assert_equal Accounts::Portability::Archive::FORMAT, archive.manifest["format"]
    end
  end

  test "not a zip" do
    refused(StringIO.new("PRIVATE plain text"), /Invalid account archive/)
  end

  test "traversal and absolute paths" do
    refused(zip_of(@members.merge("../escape.txt" => "x")), /Unsafe archive path/)
    refused(zip_of(@members.merge("field/notes/n1/../../../x" => "x")), /Unsafe archive path/)
  end

  test "links" do
    refused(zip_of(@members, symlink: "field/notes/n1/media"), /Links and special/)
  end

  test "members outside the inventory or the allowlist" do
    refused(zip_of(@members.merge("extra.txt" => "x")), /Invalid archive inventory/)
    refused(zip_of(with_member("bin/run.sh", "#!/bin/sh")), /Unsupported archive member/)
  end

  test "a version we don't know" do
    refused(zip_of(with_manifest("format" => "souls-account/v9")), /Unsupported account archive version/)
  end

  test "conversations present without the option" do
    refused(zip_of(with_member("conversations/c1.json", "{}")), /Conversations present without the option/)
  end

  test "a reference that does not resolve" do
    setup_doc = JSON.parse(@members["setup.json"])
    setup_doc["rhythms"] << { "key" => "y9", "title" => "x", "opening" => "x", "cadence" => "daily", "time_of_day" => "08:00",
                              "timezone" => "UTC", "room_choice" => "main", "append_date" => true, "resident_keys" => [ "r404" ] }
    body = JSON.generate(setup_doc)
    m = manifest
    m["inventory"]["setup.json"] = { "size" => body.bytesize, "sha256" => Digest::SHA256.hexdigest(body) }
    refused(zip_of(@members.merge("setup.json" => body, "manifest.json" => JSON.generate(m))), /does not resolve/)
  end

  test "Field media must match its record" do
    key = JSON.parse(@members["field/index.json"])["notes"].first
    refused(zip_of(with_member("field/notes/#{key}/media", "unexpected bytes")), /Unexpected Field media/)
  end

  test "case-colliding duplicates" do
    refused(zip_of(with_member("README.MD", "x").merge("Readme.md" => "y")), /Duplicate archive entry|inventory/)
  end

end
