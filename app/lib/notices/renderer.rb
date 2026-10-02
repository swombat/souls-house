module Notices
  class Renderer

    class << self

      def section_for(agent)
        items = Notice.for_agent(agent).filter_map { |notice| render(notice, agent) }
        witness = AuditLog.where(auditable: agent, action: "export_resident_archive").order(:created_at).last
        if witness
          items << "- [platform export custody, not authored memory] A private separate-copy archive was exported #{witness.data['created_at']} by #{witness.user&.to_param}, export #{witness.data['export_id']}. This source was not moved or deleted."
        end
        custody = agent.portability_custody
        if custody.present?
          items << "- [platform custody, not authored memory] This body was restored as a separate copy from archive-declared resident #{custody['source_resident_id']} (installation #{custody['source_installation']}), export #{custody['export_id']} created #{custody['created_at']} by #{custody['exported_by']}; imported #{custody['imported_at']} by #{custody['imported_by']}. The source is preserved. Conversations/session history and old service availability are not inherited; credentials, integrations and local hook trust require deliberate reconnection/review."
        end
        return if items.empty?

        <<~TEXT.strip
          ## Notices from the house

          These are standing notices. They may appear again in later activations until their stated expiry.

          #{items.join("\n")}
        TEXT
      end

      private

      def render(notice, agent)
        text = case notice.notice_type
        when "model_changed"
          model_changed_text(notice, agent)
        when "site_renamed"
          "This platform, formerly HelixKit, is now called souls.house."
        when "announcement"
          notice.body.presence
        else
          Rails.logger.warn "[Notices::Renderer] Skipping unknown notice type #{notice.notice_type.inspect} (notice #{notice.id})"
          return
        end
        return if text.blank?

        "- [#{notice.scope} · until #{format_date(notice.expires_at)}] #{text}"
      rescue KeyError, ArgumentError, TypeError => e
        Rails.logger.warn "[Notices::Renderer] Skipping malformed notice #{notice.id}: #{e.class}: #{e.message}"
        nil
      end

      def model_changed_text(notice, agent)
        params = notice.params.to_h.stringify_keys
        changed_at = Time.iso8601(params.fetch("changed_at"))
        text = "On #{format_date(changed_at)}, #{params.fetch("agent_name")}'s configured model changed from " \
          "#{params.fetch("from")} to #{params.fetch("to")}."
        text += " This model change concerns you." if params.fetch("agent_id").to_s == agent.to_param
        text
      end

      def format_date(value)
        value.in_time_zone.to_date.strftime("%-d %B %Y")
      end

    end

  end
end
