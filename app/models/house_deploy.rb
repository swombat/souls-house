require "net/http"
require "json"

# Starts the production deploy workflows from the site-admin menu.
#
# The deploy workflows only attach the deploy key when the GitHub actor is
# the owner (see .github/workflows/deploy-house.yml), so the token used here
# acts as the owner's hand. It should be a fine-grained PAT scoped to this one
# repository with Actions read/write and nothing else, stored at
# credentials.github.deploy_token. Nothing here can choose what ships: every
# dispatch is pinned to master, which is reviewed and protected.
class HouseDeploy

  WORKFLOWS = {
    "rails" => {
      file: "deploy-rails.yml",
      name: "Deploy Rails",
      description: "Rebuild and restart the Rails app from master. This page will reconnect when it comes back."
    },
    "runtime" => {
      file: "deploy-runtime.yml",
      name: "Rebuild residents",
      description: "Rebuild resident images from master, keeping the Chaos revision they already run."
    },
    "chaos" => {
      file: "deploy-chaos.yml",
      name: "Update Chaos",
      description: "Adopt the current Chaos release in resident images."
    },
    "both" => {
      file: "deploy-both.yml",
      name: "Deploy both",
      description: "Rails and Chaos together."
    }
  }.freeze

  # Runs on its own when CI passes on master (Rails only). Listed with the
  # manual runs so the page shows every deploy, but there is no button for it.
  AUTOMATIC = {
    key: "rails_auto",
    file: "deploy-rails-on-green.yml",
    name: "Deploy Rails (automatic, after green CI)"
  }.freeze

  REF = "master"
  TIMEOUT = 10

  class Error < StandardError; end

  # (method, path, body) -> [status_code, headers_hash, parsed_body_or_nil]
  class_attribute :transport, default: ->(method, path, body) { HouseDeploy.http(method, path, body) }

  class_attribute :token_source, default: -> { Rails.application.credentials.dig(:github, :deploy_token) }

  def self.token
    token_source.call.presence
  end

  def self.configured?
    token.present?
  end

  def self.repo
    DeployInfo.repo
  end

  def self.workflows
    WORKFLOWS.map { |key, config| { key: key, name: config[:name], description: config[:description] } }
  end

  def self.dispatch!(key)
    config = WORKFLOWS.fetch(key.to_s) { raise Error, "Unknown deploy: #{key}" }
    raise Error, "No deploy token configured" unless configured?

    status, _headers, body = transport.call(:post, "/repos/#{repo}/actions/workflows/#{config[:file]}/dispatches", { ref: REF })
    return config if [ 200, 204 ].include?(status)

    raise Error, failure_message(status, body)
  end

  # Recent deploy runs, manual and automatic, newest first, plus the token's
  # expiry as GitHub reports it on every authenticated response. If only the
  # automatic listing fails, the manual runs still come back and
  # partial_error says what is missing.
  def self.status(limit: 10)
    return { configured: false, runs: [], token_expires_at: nil, error: nil } unless configured?

    status, headers, body = transport.call(:get, "/repos/#{repo}/actions/runs?event=workflow_dispatch&branch=#{REF}&per_page=50", nil)
    expires_at = parse_expiry(headers)
    unless status == 200 && body.is_a?(Hash)
      return { configured: true, runs: [], token_expires_at: expires_at, error: failure_message(status, body) }
    end

    automatic, partial_error = automatic_runs
    runs = (deploy_runs(body) + automatic).sort_by { |run| run[:created_at].to_s }.reverse.first(limit)

    { configured: true, runs: runs, token_expires_at: expires_at, error: nil, partial_error: partial_error }
  end

  def self.deploy_runs(body)
    files = WORKFLOWS.to_h { |key, config| [ ".github/workflows/#{config[:file]}", key ] }
    files[".github/workflows/#{AUTOMATIC[:file]}"] = AUTOMATIC[:key]
    names = WORKFLOWS.transform_values { |config| config[:name] }.merge(AUTOMATIC[:key] => AUTOMATIC[:name])

    Array(body.is_a?(Hash) ? body["workflow_runs"] : nil).filter_map { |run|
      key = files[run["path"].to_s.split("@").first]
      next unless key
      # A skipped automatic run is a CI run that didn't pass: nothing deployed.
      next if run["conclusion"] == "skipped"

      {
        id: run["id"],
        workflow: key,
        name: names[key],
        status: run["status"],
        conclusion: run["conclusion"],
        head_sha: run["head_sha"].to_s.first(7),
        actor: run.dig("triggering_actor", "login") || run.dig("actor", "login"),
        created_at: run["created_at"],
        updated_at: run["updated_at"],
        url: run["html_url"]
      }
    }
  end

  DEPLOYED_STEP = "Deployment verified"
  SUPERSEDED_STEP = "Master moved on, nothing deployed"

  # The automatic workflow is triggered by workflow_run, so the
  # workflow_dispatch listing never includes it. Returns [runs, error].
  #
  # A successful automatic run doesn't by itself mean anything shipped: the
  # deploy job can be skipped, or the host can find master has moved on. So
  # each finished run's outcome comes from which marker step ran, and the
  # commit shown is the one CI tested (carried in the run name), not the
  # workflow run's own head_sha.
  def self.automatic_runs(limit: 5)
    status, _headers, body = transport.call(:get, "/repos/#{repo}/actions/workflows/#{AUTOMATIC[:file]}/runs?branch=#{REF}&per_page=#{limit}", nil)
    return [ [], "Couldn't list automatic deploys: #{failure_message(status, body)}" ] unless status == 200 && body.is_a?(Hash)

    raw = Array(body["workflow_runs"]).index_by { |run| run["id"] }
    runs = deploy_runs(body).select { |run| run[:workflow] == AUTOMATIC[:key] }.first(limit).map { |run|
      tested = raw.dig(run[:id], "display_title").to_s[/\b[0-9a-f]{40}\b/]
      run.merge(head_sha: tested.to_s.first(7).presence || "?", outcome: automatic_outcome(run))
    }
    [ runs, nil ]
  end

  # deployed / superseded / not_deployed for a finished successful run; nil
  # while running or when the run itself failed (its conclusion says so).
  # Finished runs never change, so their outcome is cached.
  def self.automatic_outcome(run)
    return nil unless run[:status] == "completed" && run[:conclusion] == "success"

    Rails.cache.fetch([ "house_deploy/automatic_outcome", run[:id] ], expires_in: 1.day, skip_nil: true) do
      status, _headers, body = transport.call(:get, "/repos/#{repo}/actions/runs/#{run[:id]}/jobs", nil)
      next nil unless status == 200 && body.is_a?(Hash)

      ran = Array(body["jobs"]).flat_map { |job| Array(job["steps"]) }
        .select { |step| step["conclusion"] == "success" }.map { |step| step["name"] }
      if ran.include?(DEPLOYED_STEP) then "deployed"
      elsif ran.include?(SUPERSEDED_STEP) then "superseded"
      else "not_deployed"
      end
    end
  end

  def self.failure_message(status, body)
    detail = body.is_a?(Hash) ? body["message"] : nil
    case status
    when 401 then "GitHub rejected the deploy token (expired or revoked?)"
    when 403, 404 then "The deploy token can't run workflows on #{repo}#{": #{detail}" if detail}"
    when nil then "GitHub unreachable"
    else "GitHub returned #{status}#{": #{detail}" if detail}"
    end
  end

  def self.parse_expiry(headers)
    raw = headers.to_h.transform_keys { |k| k.to_s.downcase }["github-authentication-token-expiration"]
    raw = raw.first if raw.is_a?(Array)
    return nil if raw.blank?

    Time.zone.parse(raw.to_s)&.iso8601
  rescue ArgumentError
    nil
  end

  def self.http(method, path, body)
    uri = URI("https://api.github.com#{path}")
    request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    request["Accept"] = "application/vnd.github+json"
    request["X-GitHub-Api-Version"] = "2022-11-28"
    request["Authorization"] = "Bearer #{token}"
    if body
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
    end
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.request(request)
    end
    parsed = response.body.present? ? (JSON.parse(response.body) rescue nil) : nil
    [ response.code.to_i, response.each_header.to_h, parsed ]
  rescue StandardError => e
    Rails.logger.warn("[HouseDeploy] #{method} #{path}: #{e.class}: #{e.message}")
    [ nil, {}, nil ]
  end

end
