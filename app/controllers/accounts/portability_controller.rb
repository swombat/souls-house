# Settings → Export and import (docs/features/account-portability.md).
class Accounts::PortabilityController < ApplicationController

  include Accounts::PortabilityPrivacy

  before_action :require_account_owner!

  def show
    render inertia: "accounts/portability", props: {
      account: current_account.as_json,
      exports: current_account.account_exports.recent_first.limit(10).map { |export| export_json(export) },
      imports: current_account.account_imports.recent_first.limit(10).map(&:as_json),
      residents: current_account.agents.order(:name).map do |agent|
        { name: agent.name, exportable: Agents::Portability::Export.unavailable_reason(agent).nil?,
          reason: Agents::Portability::Export.unavailable_reason(agent) }
      end,
      destination_refusal: Accounts::Portability::Import.destination_refusal(current_account),
      limits: Accounts::Portability::Archive.limits,
      never_travels: Accounts::Portability::Export::NEVER_TRAVELS,
      conversations_warning: Accounts::Portability::Archive::CONVERSATIONS_WARNING,
      export_url: account_exports_path(current_account),
      import_url: account_imports_path(current_account)
    }
  end

  private

  def export_json(export)
    export.as_json.merge(download_url: export.downloadable? ? download_account_export_path(current_account, export) : nil)
  end

end
