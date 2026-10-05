module Admin
  class MonitoringReport

    include Rails.application.routes.url_helpers

    class InvalidInput < StandardError; end

    MAX_WINDOW = 31.days
    TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z\z/

    def initialize(params, now: Time.current)
      @params = params
      @now = now.utc.change(usec: now.usec)
      if params.key?(:from) || params.key?(:to)
        @from = timestamp(params[:from])
        @to = timestamp(params[:to])
      else
        @from = @now - 1.day
        @to = @now
      end
      raise InvalidInput, "Window must be positive and no longer than 31 days" unless @to > @from && @to - @from <= MAX_WINDOW
    end

    def summary
      messages = in_window(Message.kept.joins(:chat)
        .where(chats: { discarded_at: nil }, role: %w[user assistant], progress_message: false))
      roles = messages.group(:role).count
      metadata.merge(counts: {
        new_accounts: in_window(Account.all).count,
        new_users: in_window(User.all).count,
        active_accounts: messages.distinct.count("chats.account_id"),
        human_messages: roles.fetch("user", 0),
        assistant_messages: roles.fetch("assistant", 0)
      })
    end

    def accounts
      listing(Account.includes(owner: :profile), "accounts") do |account|
        {
          id: account.to_param, name: safe_name(account.name),
          created_at: account.created_at.utc.iso8601(6),
          admin_path: admin_accounts_path(account_id: account.to_param),
          owner: account.owner && user_identity(account.owner)
        }
      end
    end

    def users
      listing(User.includes(:profile, :personal_account), "users") do |user|
        user_identity(user).merge(
          created_at: user.created_at.utc.iso8601(6),
          admin_path: user.personal_account && admin_accounts_path(account_id: user.personal_account.to_param)
        )
      end
    end

    private

    def metadata
      { window: { from: @from.iso8601(6), to: @to.iso8601(6) }, generated_at: @now.iso8601(6) }
    end

    def in_window(scope)
      scope.where(scope.klass.table_name => { created_at: @from...@to })
    end

    def timestamp(value)
      raise InvalidInput, "Use UTC timestamps with seconds and Z for both from and to" unless value.is_a?(String) && TIMESTAMP.match?(value)

      # DateTime rejects impossible dates which Time.iso8601 can normalize.
      DateTime.iso8601(value)
      time = Time.iso8601(value)
      raise InvalidInput, "Invalid UTC timestamp" unless time.strftime("%Y-%m-%dT%H:%M:%S") == value.first(19)

      time
    rescue ArgumentError
      raise InvalidInput, "Invalid UTC timestamp"
    end

    def listing(scope, kind)
      limit = page_limit
      scope = in_window(scope).reorder(created_at: :asc, id: :asc)
      if @params.key?(:cursor)
        cursor = decode_cursor(kind)
        scope = scope.where("created_at > :time OR (created_at = :time AND id > :id)",
          time: timestamp(cursor.fetch("created_at")), id: cursor.fetch("id"))
      end
      records = scope.limit(limit + 1).to_a
      has_more = records.size > limit
      records = records.first(limit)
      metadata.merge(kind => records.map { |record| yield record },
        next_cursor: has_more ? encode_cursor(records.last, kind) : nil)
    end

    def page_limit
      return 50 unless @params.key?(:limit)

      value = @params[:limit]
      unless value.is_a?(String) && /\A[1-9]\d{0,2}\z/.match?(value) && value.to_i <= 100
        raise InvalidInput, "Limit must be an integer from 1 to 100"
      end
      value.to_i
    end

    def verifier
      Rails.application.message_verifier("admin-monitoring-pagination")
    end

    def encode_cursor(record, kind)
      verifier.generate({
        "kind" => kind, "from" => @from.iso8601(6), "to" => @to.iso8601(6),
        "created_at" => record.created_at.utc.iso8601(6), "id" => record.id
      })
    end

    def decode_cursor(kind)
      value = @params[:cursor]
      raise InvalidInput, "Invalid cursor" unless value.is_a?(String) && value.bytesize.between?(1, 2048)

      cursor = verifier.verified(value)
      unless cursor.is_a?(Hash) && cursor["kind"] == kind &&
          cursor["from"] == @from.iso8601(6) && cursor["to"] == @to.iso8601(6) &&
          cursor["id"].is_a?(Integer) && cursor["id"].positive?
        raise InvalidInput, "Cursor must match the endpoint and explicit reporting window"
      end
      time = timestamp(cursor["created_at"])
      raise InvalidInput, "Cursor is outside the window" unless time >= @from && time < @to

      cursor
    end

    def user_identity(user)
      { id: user.to_param, name: safe_name(user.full_name) }
    end

    # Default personal-account labels contain email addresses. Never use the
    # email fallback in User#display_name, or expose email-bearing labels.
    def safe_name(name)
      name.presence unless name.to_s.include?("@")
    end

  end
end
