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
    refused(zip_of(@members.merge("../escape.txt" => "x")), /Unsupported archive member|Unsafe archive path/)
    refused(zip_of(@members.merge("field/notes/n1/../../../x" => "x")), /Unsupported archive member|Unsafe archive path/)
    absolute = zip_of(@members.merge("Xetc/passwd" => "x")).string.gsub("Xetc/passwd", "/etc/passwd")
    refused(StringIO.new(absolute), /Unsupported archive member|Unsafe archive path/)
  end

  test "links" do
    refused(zip_of(@members, symlink: "field/notes/n1/media"), /Links and special/)
  end

  test "members outside the inventory or the allowlist" do
    refused(zip_of(with_member("bin/run.sh", "#!/bin/sh")), /Unsupported archive member/)
    refused(zip_of(@members.merge("extra.txt" => "x")), /Unsupported archive member/)
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
    refused(zip_of(@members.merge("readme.md" => "x")), /Unsupported archive member/)
    names = @members.keys
    renamed = @members.merge("conversations/index.json" => "[]")
    refused(zip_of(renamed), /Conversations present|inventory/)
  end


  # Two central-directory records with one name: rubyzip keeps one, so the
  # raw directory is what has to refuse it.
  test "raw duplicate records are refused before rubyzip collapses them" do
    bytes = zip_of(@members.merge("field/notes/n9/item.json" => "{}", "field/notes/n8/item.json" => "{}")).string
    bytes = bytes.gsub("field/notes/n9/item.json", "field/notes/n8/item.json")
    refused(StringIO.new(bytes), /Duplicate archive entry/)
  end

  test "a path outside the layout creates nothing before it is refused" do
    deep = ([ "field" ] + Array.new(30) { |i| "d#{i}" } + [ "x" ]).join("/")
    Dir.mktmpdir do |dir|
      zip = File.join(dir, "a.zip")
      File.binwrite(zip, zip_of(@members.merge(deep => "")).string)
      stage = File.join(dir, "stage")
      Dir.mkdir(stage)
      assert_raises(Accounts::Portability::Error) { Accounts::Portability::Archive.extract(zip, stage) }
      assert_empty Dir.children(stage)
    end
  end

  test "trailing bytes after the end record are refused" do
    refused(StringIO.new(zip_of(@members).string + "hidden"), /Trailing archive data/)
  end

  # Archives over 4 GiB end in ZIP64 records. Rewrite a small archive's end
  # into that form: same members, classic end fields saturated.
  test "ZIP64 end records are read" do
    bytes = zip_of(@members).string.b
    at = bytes.rindex("PK\x05\x06".b)
    _disk, _cd_disk, _on, total, cd_size, cd_offset, _comment = bytes.byteslice(at, 22).unpack("x4vvvvVVv")
    z64_offset = at
    z64 = [ 0x06064b50, 44, 45, 45, 0, 0, total, total, cd_size, cd_offset ].pack("VQ<vvVVQ<Q<Q<Q<")
    locator = [ 0x07064b50, 0, z64_offset, 1 ].pack("VVQ<V")
    eocd = [ 0x06054b50, 0, 0, 0xFFFF, 0xFFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, 0 ].pack("VvvvvVVv")
    zip64 = bytes.byteslice(0, at) + z64 + locator + eocd
    Accounts::Portability::Archive.with_file(StringIO.new(zip64)) do |archive|
      assert_equal 1, archive.preview[:field]["notes"]
    end
  end


  test "the pre-scan never holds the central directory whole" do
    members = @members.merge((1..400).to_h { |i| [ "field/notes/n#{i + 100}/item.json", "{}" ] })
    sizes = []
    spy = Module.new { define_method(:read) { |length = nil, *rest| sizes << length; super(length, *rest) } }
    Dir.mktmpdir do |dir|
      zip = File.join(dir, "a.zip")
      File.binwrite(zip, zip_of(members).string)
      real = File.method(:open)
      File.stub(:open, ->(*args, **kw, &block) { real.call(*args, **kw) { |io| io.extend(spy) if args.first == zip; block.call(io) } }) do
        assert_equal members.length, Accounts::Portability::Archive.prescan!(zip).length
      end
    end
    assert_operator sizes.compact.max, :<=, 22 + 65_535, "a read larger than the end-record window"
    assert_operator sizes.count(46), :>=, 400, "headers are read one at a time"
  end

end
