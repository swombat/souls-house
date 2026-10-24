require "test_helper"

class Agents::PortabilityStageTest < ActiveSupport::TestCase

  Archive = Agents::Portability::Archive
  Stage = Agents::Portability::Stage
  Error = Agents::Portability::Error

  class FakeTransport

    def stopped! = true

    def capture(root, output)
      Gem::Package::TarWriter.new(output) do |tar|
        tar.mkdir(".", 0755)
        files = root == "identity" ? { "soul.md" => "Authored soul", "automation/run.sh" => "#!/bin/sh\nexit 0\n" } : { "#{root}.txt" => "the #{root} home" }
        files.each do |name, body|
          tar.add_file_simple("./#{name}", name.end_with?(".sh") ? 0755 : 0644, body.bytesize) { |file| file.write(body) }
        end
      end
    end

  end

  setup do
    @source = agents(:research_assistant)
    @source.update_columns(uuid: SecureRandom.uuid, runtime: "offline", active: false, paused: true)
    @user = users(:user_1)
    @target = accounts(:team_account).agents.create!(name: "Staged copy", model_id: @source.model_id, runtime: "offline", active: false, paused: true)
  end

  def with_archive
    Agents::Config.stub(:internal_url, "http://synthetic.invalid") do
      Agents::Portability::Export.call(@source, exporter: @user, transport: FakeTransport.new) do |path|
        File.open(path, "rb") { |file| Archive.with_upload(file) { |archive| yield archive } }
      end
    end
  end

  def unpack(bytes)
    files = {}
    Zlib::GzipReader.wrap(StringIO.new(bytes)) do |gz|
      Gem::Package::TarReader.new(gz) do |tar|
        tar.each { |entry| files[entry.full_name] = entry.directory? ? :directory : [ entry.read.to_s, entry.header.mode & 0777 ] }
      end
    end
    files
  end

  test "persists one digest-checked gzip tarball per role that outlives the upload" do
    with_archive { |archive| Stage.persist!(archive, @target) }

    stages = AgentImportStage.where(agent: @target).index_by(&:role)
    assert_equal %w[identity repo work], stages.keys.sort
    stages.each_value do |stage|
      stage.reload
      assert_equal Digest::SHA256.hexdigest(stage.archive), stage.sha256
      assert_equal stage.archive.bytesize, stage.bytes
    end
    identity = unpack(stages["identity"].archive)
    assert_equal [ "Authored soul", 0644 ], identity["soul.md"]
    assert_equal [ "#!/bin/sh\nexit 0\n", 0755 ], identity["automation/run.sh"]
    assert_equal [ "the work home", 0644 ], unpack(stages["work"].archive)["work.txt"]
    refute unpack(stages["repo"].archive).key?("soul.md")
  end

  test "the staged bytes are the bytes a local restore gets" do
    with_archive do |archive|
      Stage.persist!(archive, @target)
      local = StringIO.new("".b)
      archive.write_role_tar("identity", local)
      staged = Zlib::GzipReader.wrap(StringIO.new(@target.import_stages.find_by!(role: "identity").archive), &:read)
      assert_equal local.string, staged
    end
  end

  test "a role larger than the runner seed limit is refused and nothing is kept" do
    with_archive do |archive|
      Stage.stub(:max_role_bytes, 10) do
        error = assert_raises(Error) { AgentImportStage.transaction { Stage.persist!(archive, @target) } }
        assert_match(/larger than a resident server can be seeded with/, error.message)
      end
      assert_empty Dir.glob(File.join(archive.stage, "seed-*"))
    end
    assert_equal 0, AgentImportStage.where(agent: @target).count
  end

  test "a role the runner would refuse to unpack is refused before anything is built" do
    with_archive do |archive|
      Stage.stub(:max_role_unpacked, 5) do
        error = assert_raises(Error) { Stage.persist!(archive, @target) }
        assert_match(/MB unpacked/, error.message)
      end
      Stage.stub(:max_role_entries, 1) do
        error = assert_raises(Error) { Stage.persist!(archive, @target) }
        assert_match(/more files than/, error.message)
      end
      assert_empty Dir.glob(File.join(archive.stage, "seed-*"))
    end
    assert_equal 0, AgentImportStage.where(agent: @target).count
  end

  test "the role limits are the runner's seed limits" do
    runner = Rails.root.join("host-runner/souls_house_runner.py").read
    limit = ->(name) { runner[/^#{name} = ([\d *]+)$/, 1].split("*").map(&:to_i).reduce(:*) }
    assert_equal limit.call("SEED_MAX_BYTES"), Stage::MAX_ROLE_BYTES
    assert_equal limit.call("SEED_MAX_UNPACKED"), Stage::MAX_ROLE_UNPACKED
    assert_equal limit.call("SEED_MAX_ENTRIES"), Stage::MAX_ROLE_ENTRIES
  end

  test "an existing stage is never replaced" do
    with_archive do |archive|
      Stage.persist!(archive, @target)
      before = @target.import_stages.pluck(:role, :sha256).sort
      assert_raises(Error) { Stage.persist!(archive, @target) }
      assert_equal before, @target.import_stages.pluck(:role, :sha256).sort
    end
  end

  test "a stage whose bytes do not match its digest is invalid" do
    stage = @target.import_stages.new(role: "identity", archive: "abc".b, sha256: Digest::SHA256.hexdigest("abd"), bytes: 3)
    refute stage.valid?
    assert stage.errors[:sha256].any?
    stage.role = "chaos"
    refute stage.valid?
    assert stage.errors[:role].any?
  end

  test "deleting the resident deletes its stage" do
    with_archive { |archive| Stage.persist!(archive, @target) }
    @target.destroy!
    assert_equal 0, AgentImportStage.where(agent_id: @target.id).count
  end

end
