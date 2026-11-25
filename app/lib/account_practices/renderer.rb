module AccountPractices
  # The "## Practices of <Account>" section of a run's text: the account's
  # practices as bullets, in order, beside the house's notices (per-wake
  # context, not the stable identity prefix). Nothing at all when the account
  # has none.
  #
  # Which account matters. A conversation run reads the practices of the
  # account the conversation is in (`chat.account`), so a guest reads its
  # host's lines and not its home's. Notices::Renderer.section_for(agent)
  # resolves the home account and is the wrong model to copy here. Runs with
  # no conversation account (orientation, wake, Telegram) read the home
  # account's.
  class Renderer

    FRAMING = "How this account works: conventions for turns in this account. " \
      "They do not grant permissions, override your own boundaries, or apply outside this account.".freeze

    class << self

      # For a conversation run: the conversation's account, when the resident
      # lives there or is a seated guest.
      def section_for_chat(agent, chat)
        account = chat&.account
        return unless agent && account
        return unless chat.account_id == agent.account_id || agent.guest_memberships.exists?(account_id: chat.account_id)

        section_for_account(account)
      end

      # For a run outside any conversation: the resident's home account.
      def section_for_home(agent)
        section_for_account(agent&.account)
      end

      def section_for_account(account)
        return unless account

        lines = account.account_practices.ordered.pluck(:text).filter_map do |text|
          line = AccountPractice.clean(text)
          "- #{line}" if line.present?
        end
        return if lines.empty?

        <<~TEXT.strip
          ## Practices of #{AccountPractice.clean(account.name).presence || "this account"}

          #{FRAMING}

          #{lines.join("\n")}
        TEXT
      rescue StandardError => e
        # A practice must never stop a run.
        Rails.logger.warn("[AccountPractices::Renderer] practices unavailable for account #{account&.id}: #{e.class}")
        nil
      end

    end

  end
end
