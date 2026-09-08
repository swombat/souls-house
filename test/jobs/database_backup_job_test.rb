require "test_helper"
require "aws-sdk-s3"
require "ostruct"

class DatabaseBackupJobTest < ActiveJob::TestCase

  # Approved carve-out: these stubs exercise local credentials, ENV, and pg_dump
  # command construction. There is no HTTP provider boundary for VCR to cover.

  test "raises ArgumentError when postgres_bucket not configured" do
    empty_credentials = OpenStruct.new(aws: {})

    Rails.application.stub(:credentials, empty_credentials) do
      error = assert_raises(ArgumentError) do
        job = DatabaseBackupJob.new
        job.send(:bucket_name)
      end
      assert_match(/postgres_bucket not configured/, error.message)
    end
  end

  test "aws_credentials raises ArgumentError when the aws block is entirely absent" do
    empty_credentials = OpenStruct.new(aws: nil)

    Rails.application.stub(:credentials, empty_credentials) do
      error = assert_raises(ArgumentError) do
        DatabaseBackupJob.new.send(:aws_credentials)
      end
      assert_match(/aws credentials not configured/, error.message)
    end
  end

  test "parses DATABASE_URL correctly" do
    job = DatabaseBackupJob.new

    ENV.stub(:[], ->(key) { key == "DATABASE_URL" ? "postgres://myuser:mypass@localhost:5432/mydb" : nil }) do
      ENV.stub(:fetch, ->(key, default = nil) { ENV[key] || default }) do
        job.instance_variable_set(:@db_config, nil) # Clear memoization

        # Use present? stub since that's what the code checks
        original_present = "postgres://myuser:mypass@localhost:5432/mydb".method(:present?)
        config = job.send(:db_config)

        assert_equal "localhost", config[:host]
        assert_equal 5432, config[:port]
        assert_equal "myuser", config[:username]
        assert_equal "mypass", config[:password]
        assert_equal "mydb", config[:database]
      end
    end
  end

  test "builds pg_dump args with all options" do
    job = DatabaseBackupJob.new

    job.stub(:db_config, { host: "db.example.com", port: 5432, username: "dbuser", password: "secret", database: "myapp" }) do
      args = job.send(:pg_dump_args)

      assert_includes args, "pg_dump"
      assert_includes args, "-h"
      assert_includes args, "db.example.com"
      assert_includes args, "-p"
      assert_includes args, "5432"
      assert_includes args, "-U"
      assert_includes args, "dbuser"
      assert_includes args, "-d"
      assert_includes args, "myapp"
      assert_includes args, "--no-owner"
      assert_includes args, "--no-acl"
    end
  end

  test "builds pg_dump args without optional fields" do
    job = DatabaseBackupJob.new

    job.stub(:db_config, { database: "myapp", host: nil, port: nil, username: nil, password: nil }) do
      args = job.send(:pg_dump_args)

      assert_includes args, "pg_dump"
      assert_includes args, "-d"
      assert_includes args, "myapp"
      refute_includes args, "-h"
      refute_includes args, "-p"
      refute_includes args, "-U"
    end
  end

  test "pg_dump_env includes password when present" do
    job = DatabaseBackupJob.new

    job.stub(:db_config, { password: "secret123" }) do
      env = job.send(:pg_dump_env)
      assert_equal "secret123", env["PGPASSWORD"]
    end
  end

  test "pg_dump_env is empty when no password" do
    job = DatabaseBackupJob.new

    job.stub(:db_config, { password: nil }) do
      env = job.send(:pg_dump_env)
      assert_empty env
    end
  end

  test "aws_credentials extracts correct values" do
    mock_credentials = OpenStruct.new(
      aws: {
        access_key_id: "AKIATEST",
        secret_access_key: "secret123",
        s3_region: "us-west-2",
        postgres_bucket: "my-bucket"
      }
    )

    Rails.application.stub(:credentials, mock_credentials) do
      job = DatabaseBackupJob.new
      creds = job.send(:aws_credentials)

      assert_equal "AKIATEST", creds[:access_key_id]
      assert_equal "secret123", creds[:secret_access_key]
      assert_equal "us-west-2", creds[:region]
    end
  end

end
