require "aws-sdk-s3"
require "open3"

class DatabaseBackupJob < ApplicationJob

  queue_as :default
  retry_on Aws::S3::Errors::ServiceError, wait: :polynomially_longer, attempts: 3

  def perform
    timestamp = Time.current.strftime("%Y-%m-%d_%H-%M-%S")
    filename = "#{db_config[:database] || 'helix_kit'}_#{timestamp}.sql.gz"

    Rails.logger.info "Starting database backup: #{filename}"

    Tempfile.create([ "backup", ".sql.gz" ]) do |tempfile|
      create_compressed_backup(tempfile.path)
      upload_to_s3(tempfile.path, filename)
    end

    Rails.logger.info "Database backup completed: #{filename}"
  rescue StandardError => e
    Rails.logger.error "Database backup failed: #{e.class} - #{e.message}"
    raise
  end

  private

  def create_compressed_backup(output_path)
    stdout, stderr, status = Open3.capture3(pg_dump_env, *pg_dump_args)

    raise "pg_dump failed: #{stderr}" unless status.success?

    File.binwrite(output_path, ActiveSupport::Gzip.compress(stdout))
  end

  def pg_dump_env
    { "PGPASSWORD" => db_config[:password] }.compact
  end

  def pg_dump_args
    config = db_config
    args = [ "pg_dump" ]

    args.push("-h", config[:host]) if config[:host]
    args.push("-p", config[:port].to_s) if config[:port]
    args.push("-U", config[:username]) if config[:username]
    args.push("-d", config[:database])
    args.push("--no-owner", "--no-acl")

    args
  end

  def db_config
    @db_config ||= if ENV["DATABASE_URL"].present?
      uri = URI.parse(ENV["DATABASE_URL"])
      {
        host: uri.host,
        port: uri.port,
        username: uri.user,
        password: uri.password,
        database: uri.path.delete_prefix("/")
      }
    else
      ActiveRecord::Base.connection_db_config.configuration_hash
        .slice(:host, :port, :username, :password, :database)
    end
  end

  def upload_to_s3(file_path, filename)
    File.open(file_path, "rb") do |io|
      s3_client.put_object(bucket: bucket_name, key: filename, body: io)
    end
  end

  def s3_client
    @s3_client ||= Aws::S3::Client.new(**aws_credentials)
  end

  def aws_credentials
    creds = Rails.application.credentials.aws
    if creds.blank?
      raise ArgumentError, "aws credentials not configured; set aws.access_key_id, aws.secret_access_key, aws.s3_region and aws.postgres_bucket (see config/credentials/production.example.yml)"
    end
    {
      access_key_id: creds[:access_key_id],
      secret_access_key: creds[:secret_access_key],
      region: creds[:s3_region]
    }
  end

  def bucket_name
    Rails.application.credentials.dig(:aws, :postgres_bucket) or
      raise ArgumentError, "aws.postgres_bucket not configured in credentials"
  end

end
