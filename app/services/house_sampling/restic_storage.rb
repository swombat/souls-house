module HouseSampling
  # Bytes Restic actually stores in S3 for one resident (after dedup and
  # compression), by listing the repository prefix. Read-only: no restic
  # password, no repository lock.
  class ResticStorage

    def initialize(client: nil)
      @client = client
    end

    def enabled?
      !Backup::LocalRepository.enabled? && Backup::AgentRestic.bucket.present?
    rescue ArgumentError
      false
    end

    def call(agent)
      prefix = "agents/#{agent.uuid}/"
      bytes = 0
      objects = 0
      client.list_objects_v2(bucket: Backup::AgentRestic.bucket, prefix:).each do |page|
        page.contents.each do |object|
          bytes += object.size.to_i
          objects += 1
        end
      end
      { "bytes" => bytes, "objects" => objects }
    end

    private

    def client
      @client ||= begin
        require "aws-sdk-s3"
        Aws::S3::Client.new(
          region: Backup::AgentRestic.region,
          access_key_id: Backup::AgentRestic.aws_value(:access_key_id),
          secret_access_key: Backup::AgentRestic.aws_value(:secret_access_key)
        )
      end
    end

  end
end
