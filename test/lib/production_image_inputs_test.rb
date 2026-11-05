require "test_helper"

# The production image is built from an explicit COPY list. A file Rails reads
# or runs from agent-runtime/ or host-runner/ that is left out of it fails only
# in production: the runner on 2026-10-08, and on 2026-11-01 the GitHub import
# validator, whose absence every import reported as "check the manifest".
class ProductionImageInputsTest < ActiveSupport::TestCase

  REFERENCE = %r{Rails\.root\.join\("((?:agent-runtime|host-runner)/[^"]+\.[a-z]+)"\)}

  test "every agent-runtime and host-runner file the app reads is copied into the image" do
    dockerfile = Rails.root.join("Dockerfile").read
    referenced = Dir[Rails.root.join("app/**/*.rb")].flat_map { |file| File.read(file).scan(REFERENCE).flatten }.uniq

    assert_includes referenced, "agent-runtime/imported_home.py", "the scan should see the import validator"
    referenced.each do |path|
      assert dockerfile.include?("COPY #{path} #{path}"), "#{path} is used by the app but not copied into the production image"
    end
    assert_includes dockerfile, "COPY --from=build --chown=rails:rails /rails/agent-runtime /rails/agent-runtime"
  end

  # RunnerUserData names its package members in constants, which the scan
  # above can't see; the full package (#426 3C) is built in production too.
  test "every runner package member is copied into the image" do
    dockerfile = Rails.root.join("Dockerfile").read
    (RunnerUserData::BIRTH_FILES + RunnerUserData::CARRY_FILES).each do |name|
      path = "host-runner/#{name}"
      assert dockerfile.include?("COPY #{path} #{path}"), "#{path} is in a runner package but not copied into the production image"
    end
  end

  test "the import validator's own import is copied beside it" do
    validator = Rails.root.join("agent-runtime/imported_home.py").read
    assert_match(/from standard_home_sync import/, validator)
    assert Rails.root.join("Dockerfile").read.include?("COPY agent-runtime/standard_home_sync.py agent-runtime/standard_home_sync.py"),
      "imported_home.py imports standard_home_sync, which is not copied into the production image"
  end

end
