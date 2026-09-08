require "test_helper"
require Rails.root.join("lib/house/init")
require "active_support/encrypted_file"
require "tmpdir"
require "fileutils"

class FreshCredentialsTest < ActiveSupport::TestCase

  test "fresh credentials are seeded with a private new key before the editor runs" do
    with_credentials do |root, init, enc, key|
      init.stub(:system, ->(*_args, **_options) {
        assert_equal "example: value\n", read_credentials(enc, key)
        assert_equal 0o600, File.stat(key).mode & 0o777
        true
      }) do
        assert init.send(:offer_fresh_credentials)
      end
      assert_equal "original ciphertext", File.read("#{enc}.backup")
      assert_equal "example: value\n", read_credentials(enc, key)
    end
  end

  test "editor failure restores original ciphertext and removes new key" do
    with_credentials do |_root, init, enc, key|
      init.stub(:system, false) do
        assert_equal false, init.send(:offer_fresh_credentials)
      end
      assert_equal "original ciphertext", File.read(enc)
      assert_not File.exist?(key)
      assert_not File.exist?("#{enc}.backup")
    end
  end

  test "seed failure leaves original ciphertext intact" do
    with_credentials do |_root, init, enc, key|
      ActiveSupport::EncryptedFile.stub(:generate_key, -> { raise IOError, "synthetic failure" }) do
        assert_equal false, init.send(:offer_fresh_credentials)
      end
      assert_equal "original ciphertext", File.read(enc)
      assert_not File.exist?(key)
    end
  end

  test "existing production key prevents automatic replacement" do
    with_credentials do |_root, init, enc, key|
      File.write(key, "existing key")
      assert init.send(:offer_fresh_credentials)
      assert_equal "existing key", File.read(key)
      assert_equal "original ciphertext", File.read(enc)
    end
  end

  test "exported production key prevents automatic replacement" do
    with_credentials do |_root, init, enc, key|
      ENV["RAILS_MASTER_KEY"] = "synthetic-existing-key"
      assert init.send(:offer_fresh_credentials)
      assert_equal "original ciphertext", File.read(enc)
      assert_not File.exist?(key)
    end
  end

  test "non-interactive initialization never opens the credential editor" do
    with_credentials do |root, _init, enc, key|
      answers = "#{root}/answers.env"
      File.write(answers, "")
      stdin = Object.new
      def stdin.gets
        raise "Non-interactive setup must not read stdin"
      end
      init = House::Init.new(root: root, from: answers, stdin: stdin, out: StringIO.new)
      assert init.run
      assert_equal "original ciphertext", File.read(enc)
      assert_not File.exist?(key)
    end
  end

  test "existing backup is not overwritten" do
    with_credentials do |_root, init, enc, key|
      File.write("#{enc}.backup", "older ciphertext")
      assert_equal false, init.send(:offer_fresh_credentials)
      assert_equal "older ciphertext", File.read("#{enc}.backup")
      assert_equal "original ciphertext", File.read(enc)
      assert_not File.exist?(key)
    end
  end

  test "init propagates credential setup failure" do
    with_credentials do |_root, init, _enc, _key|
      init.stub(:prompt, ->(entry) { entry[:default] }) do
        init.stub(:system, false) do
          assert_equal false, init.run
        end
      end
    end
  end

  private

  def read_credentials(enc, key)
    ActiveSupport::EncryptedFile.new(content_path: enc, key_path: key,
                                    env_key: "RAILS_MASTER_KEY", raise_if_missing_key: true).read
  end

  def with_credentials
    previous = ENV.to_h.slice("EDITOR", "RAILS_MASTER_KEY")
    ENV["EDITOR"] = "stubbed-editor"
    ENV.delete("RAILS_MASTER_KEY")
    Dir.mktmpdir("fresh-credentials-test") do |root|
      FileUtils.mkdir_p("#{root}/config/credentials")
      FileUtils.cp(Rails.root.join("config/house.env.example"), "#{root}/config/house.env.example")
      File.write("#{root}/config/credentials/production.example.yml", "example: value\n")
      enc = "#{root}/config/credentials/production.yml.enc"
      key = "#{root}/config/credentials/production.key"
      File.write(enc, "original ciphertext")
      init = House::Init.new(root: root, stdin: StringIO.new("y\n"), out: StringIO.new)
      yield root, init, enc, key
    end
  ensure
    %w[EDITOR RAILS_MASTER_KEY].each { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
  end

end
