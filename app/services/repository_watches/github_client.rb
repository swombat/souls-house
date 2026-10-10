require "net/http"
require "json"

module RepositoryWatches
  # The few GitHub REST calls repository watches need, made with a GitHub
  # ServiceConnection's own token. Nothing here fetches a URL taken from a
  # webhook payload: every path is built from the stored repository name.
  class GithubClient

    API_ROOT = "https://api.github.com".freeze
    API_VERSION = "2022-11-28".freeze
    FULL_NAME = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}

    # status is GitHub's HTTP status (nil when GitHub could not be reached).
    class Error < StandardError

      attr_reader :status

      def initialize(message, status: nil)
        super(message)
        @status = status
      end

      def access_refused?
        status.in?([ 403, 404 ])
      end

    end

    def initialize(connection)
      @connection = connection
    end

    def repository(full_name)
      request(:get, "/repos/#{checked(full_name)}")
    end

    # Repositories this token can see, most recently updated first.
    def repositories
      Array(request(:get, "/user/repos", params: { sort: "updated", direction: "desc", per_page: 100 }))
    end

    def create_hook(full_name, url:, secret:)
      request(:post, "/repos/#{checked(full_name)}/hooks", body: {
        name: "web",
        active: true,
        events: %w[workflow_run deployment_status],
        config: { url: url, content_type: "json", secret: secret, insecure_ssl: "0" }
      })
    end

    def delete_hook(full_name, hook_id)
      request(:delete, "/repos/#{checked(full_name)}/hooks/#{Integer(hook_id)}")
    end

    # The full sha for a commit-ish (a short sha), or raises.
    def commit_sha(full_name, ref)
      request(:get, "/repos/#{checked(full_name)}/commits/#{ref}").fetch("sha")
    end

    def workflow_runs(full_name, head_sha:)
      data = request(:get, "/repos/#{checked(full_name)}/actions/runs", params: { head_sha: head_sha, per_page: 100 })
      Array(data && data["workflow_runs"])
    end

    def deployments(full_name, sha: nil, environment: nil)
      params = { per_page: 30, sha: sha, environment: environment }.compact
      Array(request(:get, "/repos/#{checked(full_name)}/deployments", params: params))
    end

    # Newest first, as GitHub returns them.
    def deployment_statuses(full_name, deployment_id)
      Array(request(:get, "/repos/#{checked(full_name)}/deployments/#{Integer(deployment_id)}/statuses", params: { per_page: 10 }))
    end

    private

    def token
      @connection.credential_payload_hash["token"].presence || raise(Error.new("The GitHub connection has no token"))
    end

    def checked(full_name)
      raise Error.new("Repository must be owner/name") unless full_name.to_s.match?(FULL_NAME)

      full_name
    end

    def request(method, path, params: {}, body: nil)
      uri = URI("#{API_ROOT}#{path}")
      uri.query = URI.encode_www_form(params) if params.any?
      request = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method).new(uri)
      request["Accept"] = "application/vnd.github+json"
      request["Authorization"] = "Bearer #{token}"
      request["X-GitHub-Api-Version"] = API_VERSION
      request["User-Agent"] = "souls.house repository watches"
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15) do |http|
        http.request(request)
      end
      status = response.code.to_i
      raise Error.new(failure_message(status, response), status: status) unless response.is_a?(Net::HTTPSuccess)
      return nil if response.body.blank?

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error.new("GitHub returned invalid JSON", status: status)
    rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError => error
      raise Error.new("GitHub could not be reached (#{error.class.name.demodulize})")
    end

    # Short and free of secrets: GitHub's own message, truncated.
    def failure_message(status, response)
      detail = begin
        JSON.parse(response.body.to_s)["message"]
      rescue JSON::ParserError
        nil
      end
      [ "GitHub answered #{status}", detail.to_s.truncate(120).presence ].compact.join(": ")
    end

  end
end
