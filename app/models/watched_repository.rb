# One repository an account has connected for watches: one webhook on GitHub,
# however many watches are armed on it. Connected through a GitHub
# ServiceConnection by a person who can manage it, or by a resident holding an
# enabled grant on it; watches are then armed on it (RepositoryWatch).
#
# The hook is installed with the connection's token. GitHub refuses that
# unless the token's owner is an admin of the repository; then the status is
# "manual" and the card shows the receiver URL and secret for someone who is.
# So a grant never becomes more than the connection's own GitHub permission:
# GitHub, not the house, decides whether the hook can be installed.
# Either way the hook counts as installed only once GitHub's signed ping
# arrives (RepositoryWebhooksController).
class WatchedRepository < ApplicationRecord

  HOOK_STATUSES = %w[installing installed manual failed removed].freeze
  DELIVERY_RESULTS = %w[verified rejected ignored].freeze

  belongs_to :account
  belongs_to :service_connection
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :created_by_agent, class_name: "Agent", optional: true
  has_many :repository_watches, dependent: :delete_all
  has_many :repository_deliveries, dependent: :delete_all

  encrypts :hook_secret

  validates :provider, inclusion: { in: %w[github] }
  validates :hook_status, inclusion: { in: HOOK_STATUSES }
  validates :last_delivery_result, inclusion: { in: DELIVERY_RESULTS }, allow_nil: true
  validates :full_name, format: { with: RepositoryWatches::GithubClient::FULL_NAME }
  validates :full_name, uniqueness: { scope: [ :account_id, :provider ], conditions: -> { where(removed_at: nil) }, case_sensitive: false }
  validate :connection_matches

  before_validation :generate_secrets, on: :create

  scope :live, -> { where(removed_at: nil) }

  class ConnectError < StandardError; end

  # Connect a repository and try to install its hook. Returns the record, in
  # whatever hook status GitHub's answer leaves it.
  # `by` is the User or Agent connecting it; authority is the caller's check.
  def self.connect!(connection:, full_name:, by:)
    raise ConnectError, "Repository watches need a GitHub connection" unless connection.provider == "github"
    raise ConnectError, "That GitHub connection is not connected" unless connection.status == "connected"

    client = RepositoryWatches::GithubClient.new(connection)
    begin
      info = client.repository(full_name.to_s.strip)
    rescue RepositoryWatches::GithubClient::Error => error
      raise ConnectError, error.access_refused? ? "This GitHub connection cannot see #{full_name}" : error.message
    end

    owner, name = info.fetch("full_name").split("/", 2)
    repository = create!(
      account: connection.account,
      service_connection: connection,
      created_by_user: (by if by.is_a?(User)),
      created_by_agent: (by if by.is_a?(Agent)),
      owner: owner,
      name: name,
      full_name: info.fetch("full_name"),
      external_repository_id: info["id"]&.to_s,
      private_repository: info["private"] != false
    )
    repository.install_hook!(client)
    repository
  rescue ActiveRecord::RecordInvalid => error
    raise ConnectError, error.record.errors.full_messages.to_sentence
  end

  def install_hook!(client = RepositoryWatches::GithubClient.new(service_connection))
    hook = client.create_hook(full_name, url: receiver_url, secret: hook_secret)
    update!(hook_id: hook["id"], hook_status: "installing", hook_error: nil)
  rescue ConnectError => error
    update!(hook_status: "failed", hook_error: error.message.truncate(200))
  rescue RepositoryWatches::GithubClient::Error => error
    if error.access_refused?
      update!(hook_status: "manual", hook_error: "GitHub refused to install the hook (an admin of #{full_name} must add it)")
    else
      update!(hook_status: "failed", hook_error: error.message.truncate(200))
    end
  end

  def receiver_url
    base = Rails.configuration.x.public_url.to_s
    raise ConnectError, "The house has no public URL (set SOULSHOUSE_PUBLIC_URL), so GitHub has nowhere to send deliveries" if base.blank?

    "#{base.chomp('/')}/webhooks/repositories/#{receiver_token}"
  end

  def removed?
    removed_at.present?
  end

  # Disconnect: delete the hook (best effort), mark removed, cancel what is
  # armed with the reason. Idempotent.
  def remove!(reason: "repository disconnected", delete_hook: true)
    return if removed?

    if delete_hook && hook_id.present? && service_connection.status == "connected"
      begin
        RepositoryWatches::GithubClient.new(service_connection).delete_hook(full_name, hook_id)
      rescue RepositoryWatches::GithubClient::Error => error
        Rails.logger.info("[RepositoryWatches] hook delete for #{full_name} failed: #{error.message}")
      end
    end
    transaction do
      update!(hook_status: "removed", removed_at: Time.current)
      repository_watches.armed.find_each { |watch| watch.cancel!(reason: reason) }
    end
  end

  def record_delivery_result!(result)
    update_columns(last_delivery_at: Time.current, last_delivery_result: result, updated_at: Time.current)
  end

  # GitHub's signed ping: the hook works, whoever installed it.
  def confirm_hook!
    update!(hook_status: "installed", hook_error: nil) if hook_status.in?(%w[installing manual failed])
  end

  def verify_signature(raw_body, header)
    RepositoryWatches::Signature.valid?(secret: hook_secret, body: raw_body, header: header)
  end

  def as_repository_json(include_setup: false)
    {
      id: to_param,
      full_name: full_name,
      provider: provider,
      service_connection_id: service_connection.public_id,
      private: private_repository,
      hook_status: hook_status,
      hook_error: hook_error,
      last_delivery_at: last_delivery_at&.utc&.iso8601,
      last_delivery_result: last_delivery_result,
      commit_badges: commit_badges,
      armed_watches: repository_watches.armed.count,
      connected_by: connected_by_json
    }.tap do |json|
      # The secret is shown only to people who may manage the repository, and
      # only while someone still has to paste it into GitHub.
      if include_setup && hook_status.in?(%w[manual failed installing])
        json[:setup] = { url: setup_url, secret: hook_secret, content_type: "application/json", events: %w[workflow_run deployment_status] }
      end
    end
  end

  private

  def connected_by_json
    if created_by_agent
      { type: "resident", id: created_by_agent.to_param, name: created_by_agent.name }
    elsif created_by_user
      { type: "person", name: created_by_user.full_name.presence || created_by_user.email_address.split("@").first }
    end
  end

  def setup_url
    receiver_url
  rescue ConnectError
    nil
  end

  def generate_secrets
    self.hook_secret ||= SecureRandom.hex(32)
    self.receiver_token ||= SecureRandom.urlsafe_base64(24)
  end

  def connection_matches
    return unless service_connection

    errors.add(:service_connection, "must belong to this account") unless service_connection.account_id == account_id
    errors.add(:service_connection, "must be a GitHub connection") unless service_connection.provider == provider
  end

end
