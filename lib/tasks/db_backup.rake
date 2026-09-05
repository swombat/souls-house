require "aws-sdk-s3"
require "tempfile"

module DbBackupHelpers

  module_function

  def ensure_not_production!
    if LocalInstance.current.namespace
      abort "Backup data import is disabled for secondary/test instances; use fresh instance setup."
    end
    if Rails.env.production?
      abort "ERROR: This task cannot be run in the production environment!"
    end
  end

  def s3_client
    @s3_client ||= Aws::S3::Client.new(
      access_key_id: credentials[:access_key_id],
      secret_access_key: credentials[:secret_access_key],
      region: credentials[:postgres_bucket_region] || credentials[:s3_region]
    )
  end

  def bucket_name
    credentials[:postgres_bucket] || abort("postgres_bucket not configured in credentials")
  end

  def credentials
    Rails.application.credentials.aws
  end

  def latest_backup_key
    keys = []
    continuation_token = nil

    loop do
      options = { bucket: bucket_name }
      options[:continuation_token] = continuation_token if continuation_token
      response = s3_client.list_objects_v2(**options)
      keys.concat(response.contents.map(&:key).select { |key| key.end_with?(".sql.gz") })
      break unless response.is_truncated

      continuation_token = response.next_continuation_token
    end

    keys.max
  end

  def latest_downloaded_sql
    Dir[download_path.join("*.sql")].max
  end

  def reset_user_passwords!
    puts "Resetting all user passwords to 'password'..."
    User.find_each do |user|
      user.update_column(:password_digest, BCrypt::Password.create("password"))
      puts "  Reset password for #{user.email_address}"
    end
    puts "All passwords reset to 'password'"
  end

  def create_test_agents!
    nexus_account_obfuscated_id = "PNvAYr"
    nexus_account_id = Account.decode_id(nexus_account_obfuscated_id)
    nexus_account = Account.find_by(id: nexus_account_id)

    unless nexus_account
      puts "Warning: Nexus account (#{nexus_account_obfuscated_id}) not found. Skipping test agent creation."
      return
    end

    creator = nexus_account.owner || nexus_account.users.first
    unless creator
      puts "Warning: #{nexus_account.name} has no user available to own test-agent API keys. Skipping test agent creation."
      return
    end

    puts "Creating Chaos-backed test agents in #{nexus_account.name} account..."

    test_agents = [
      { name: "Claude Test Agent", model_id: "anthropic/claude-haiku-4.5", colour: "violet", icon: "Sun" },
      { name: "GPT Test Agent", model_id: "openai/gpt-5.6-luna", colour: "sky", icon: "Lightning" },
      { name: "Grok Test Agent", model_id: "x-ai/grok-build-0.1", colour: "pink", icon: "Sparkle" },
      { name: "Gemini Test Agent", model_id: "google/gemini-3.7-flash", colour: "gray", icon: "PuzzlePiece" }
    ]

    test_agents.each do |config|
      existing_agent = nexus_account.agents.find_by(name: config[:name])
      if existing_agent&.deprecated?
        puts "  Preserved deprecated #{config[:name]} and its history; create a separately named resident explicitly."
        next
      end
      if existing_agent
        if existing_agent.model_id != config[:model_id]
          previous_model = existing_agent.model_id
          existing_agent.update!(model_id: config[:model_id])
          puts "  Updated #{config[:name]} from #{previous_model} to #{config[:model_id]}"
        end
        ProvisionAgentJob.perform_later(existing_agent.id) if existing_agent.provisioning?
        puts "  Kept #{config[:name]} on its existing Chaos runtime (#{existing_agent.model_id})"
        next
      end

      agent = Agents::HostedBirth.new(
        account: nexus_account,
        creator: creator,
        attributes: config.merge(
          system_prompt: "You are a test agent. Your purpose is to help with testing and development."
        )
      ).create!
      puts "  Created #{agent.name} (#{agent.model_id}); Chaos provisioning queued"
    rescue ActiveRecord::RecordInvalid, Agents::HostedProvisioning::ConfigurationError => e
      puts "  Failed to create #{config[:name]}: #{e.message}"
    end

    puts "Chaos-backed test agents created."
  end

  def download_path
    Rails.root.join("db", "backups")
  end

  def refreshing?
    Rake.application.top_level_tasks.include?("db_backup:refresh")
  end

  def with_psql_compatible_dump(sql_path)
    Tempfile.create([ "helix-kit-restore-", ".sql" ], download_path) do |file|
      File.foreach(sql_path) do |line|
        # Newer patched pg_dump clients emit these psql safety commands, but
        # older local psql patch releases reject them. This is our own trusted
        # backup, so removing only the guard commands preserves the SQL payload.
        next if line.match?(/\A\\(?:un)?restrict\b/)

        file.write(line)
      end
      file.flush
      yield file.path
    end
  end

  def migrate_restored_database!
    puts "Running local migrations against the restored database..."
    ActiveRecord::Base.connection.schema_cache.clear!
    Rake::Task["db:migrate"].reenable
    Rake::Task["db:migrate"].invoke
    ActiveRecord::Base.connection.schema_cache.clear!
  end

end

namespace :db_backup do
  include DbBackupHelpers

  desc "Show the timestamp of the latest database backup"
  task latest: :environment do
    latest = DbBackupHelpers.latest_backup_key
    if latest
      # Extract timestamp from filename like: helix_kit_production_2026-01-10_20-06-56.sql.gz
      if latest.match(/(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})/)
        timestamp_str = $1
        date_part, time_part = timestamp_str.split("_")
        formatted_time = time_part.tr("-", ":")
        puts "Latest backup: #{latest}"
        puts "Timestamp: #{date_part} at #{formatted_time}"
      else
        puts "Latest backup: #{latest}"
      end
    else
      puts "No backups found in bucket."
    end
  end

  desc "Download the latest database backup from S3"
  task download: :environment do
    DbBackupHelpers.ensure_not_production!

    latest = DbBackupHelpers.latest_backup_key
    abort "No backups found in bucket." unless latest

    FileUtils.mkdir_p(DbBackupHelpers.download_path)

    local_file = DbBackupHelpers.download_path.join(File.basename(latest))

    puts "Downloading #{latest}..."
    DbBackupHelpers.s3_client.get_object(
      bucket: DbBackupHelpers.bucket_name,
      key: latest,
      response_target: local_file.to_s
    )
    puts "Downloaded to #{local_file}"

    # Decompress
    sql_file = local_file.to_s.sub(/\.gz$/, "")
    puts "Decompressing to #{sql_file}..."
    system("gunzip -f #{local_file}")
    puts "Done. SQL file at: #{sql_file}"
  end

  desc "Restore the latest downloaded backup (overwrites local dev database!)"
  task restore: :environment do
    DbBackupHelpers.ensure_not_production!

    latest_sql = DbBackupHelpers.latest_downloaded_sql

    abort "No SQL file found in #{DbBackupHelpers.download_path}. Run `rake db_backup:download` first." unless latest_sql

    db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    dbname = db_config[:database]
    host = db_config[:host] || "localhost"
    username = db_config[:username]
    password = db_config[:password]

    puts "Restoring #{latest_sql} to #{dbname}..."
    puts "WARNING: This will DROP and recreate your local development database!"
    puts "WARNING: It will also replace restored hosted-agent containers and Docker volumes." if Rails.env.development? && DbBackupHelpers.refreshing?
    print "Continue? (y/N): "
    response = $stdin.gets.chomp
    abort "Aborted." unless response.downcase == "y"

    env = password ? { "PGPASSWORD" => password } : {}

    # Disconnect all connections and drop the database
    puts "Dropping database #{dbname}..."
    ActiveRecord::Base.connection.disconnect!

    drop_cmd = [ "dropdb" ]
    drop_cmd.push("-h", host) if host
    drop_cmd.push("-U", username) if username
    drop_cmd.push("--if-exists", dbname)
    system(env, *drop_cmd)

    # Create empty database
    puts "Creating database #{dbname}..."
    create_cmd = [ "createdb" ]
    create_cmd.push("-h", host) if host
    create_cmd.push("-U", username) if username
    create_cmd.push(dbname)
    unless system(env, *create_cmd)
      abort "Failed to create database!"
    end

    # Restore from backup
    puts "Restoring from backup..."
    restore_cmd = [ "psql", "-q", "-v", "ON_ERROR_STOP=1" ]  # -q for quiet mode
    restore_cmd.push("-h", host) if host
    restore_cmd.push("-U", username) if username
    restore_cmd.push("-d", dbname)

    success = DbBackupHelpers.with_psql_compatible_dump(latest_sql) do |restore_file|
      command = restore_cmd + [ "-f", restore_file ]
      puts "Running: #{command.join(' ')}"
      system(env, *command)
    end

    # Reconnect
    ActiveRecord::Base.establish_connection

    if success
      puts "Database restored successfully."
      DbBackupHelpers.migrate_restored_database!
      DbBackupHelpers.reset_user_passwords!
      DbBackupHelpers.create_test_agents!
    else
      abort "Database restoration failed!"
    end
  end

  task ensure_agent_restore_ready: :environment do
    DbBackupHelpers.ensure_not_production!
    Backup::AgentResticRestore.ensure_docker_available! if Rails.env.development?
  end

  desc "Download and restore the latest backup (full refresh)"
  task refresh: [ :ensure_agent_restore_ready, :download, :restore ] do
    DbBackupHelpers.ensure_not_production!
    Rake::Task["db_backup:restore_agents"].invoke if Rails.env.development?
    puts "Database refresh completed."
  end

  desc "Trigger a database and hosted Chaos-agent backup on production via Kamal"
  task :perform do
    puts "Triggering database and hosted Chaos-agent backup on production..."
    success = system('kamal app exec -r web "bin/rails runner \'FullBackupJob.perform_now(fail_fast: true)\'"')
    abort "Production backup failed." unless success
  end

  desc "Restore hosted Chaos-agent volumes from the snapshots recorded in the restored database"
  task restore_agents: :environment do
    DbBackupHelpers.ensure_not_production!
    abort "Agent restore is only supported in development." unless Rails.env.development?

    unless DbBackupHelpers.refreshing?
      puts "WARNING: This will replace local Docker volumes and containers for every restored hosted agent."
      print "Continue restoring hosted agents? (y/N): "
      response = $stdin.gets.chomp
      abort "Aborted." unless response.downcase == "y"
    end

    Backup::AgentResticRestore.restore_all!
    puts "Hosted Chaos agents restored."
  end

  desc "Create Chaos-backed test agents in the Nexus account"
  task create_test_agents: :environment do
    DbBackupHelpers.ensure_not_production!
    DbBackupHelpers.create_test_agents!
  end

  desc "Create Chaos-backed test agents in the Nexus account"
  task test_agents: :environment do
    DbBackupHelpers.ensure_not_production!
    DbBackupHelpers.create_test_agents!
  end
end
