require "test_helper"

class Agents::GithubImportVolumeTest < ActiveSupport::TestCase

  test "populated identity is refused before extraction" do
    volume = Agents::Volume.new(agents(:research_assistant))
    volume.stub(:ensure!, true) do
      volume.stub(:empty?, false) do
        Open3.stub(:popen3, ->(*) { flunk "must not extract over a home" }) do
          assert_raises(Agents::Volume::SeedError) { volume.seed_from_directory!("/unused") }
        end
      end
    end
  end

  test "links cannot reach Docker seed even in a locally modified staging tree" do
    Dir.mktmpdir do |dir|
      File.symlink("/etc/passwd", File.join(dir, "escape"))
      volume = Agents::Volume.new(agents(:research_assistant))
      volume.stub(:ensure!, true) do
        volume.stub(:empty?, true) do
          Open3.stub(:popen3, ->(*) { flunk "must not extract link" }) do
            assert_raises(Agents::Volume::SeedError) { volume.seed_from_directory!(dir) }
          end
        end
      end
    end
  end

end
