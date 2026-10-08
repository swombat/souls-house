module Api
  module V1
    module Accounts
      # Standing announcements to every resident in the account, as on the
      # account's notices page. The web has no role guard beyond membership.
      class NoticesController < BaseController

        include ApiAccountAdministration

        def index
          render json: {
            notices: managed_notices.order(created_at: :desc).map { |notice| notice_json(notice) },
            expiry_days_options: Notice::EXPIRY_DAYS
          }
        end

        def create
          notice = Notice.announce_to_account!(
            account: @account,
            body: params[:body].is_a?(String) ? params[:body] : nil,
            expires_in_days: params[:expires_in_days],
            created_by: current_api_user
          )
          audit("create_account_notice", notice, expires_at: notice.expires_at)
          render json: { notice: notice_json(notice) }, status: :created
        rescue ActiveRecord::RecordInvalid => error
          render_invalid(error.record)
        end

        # Ends the notice now, as the web does; the row is kept.
        def destroy
          notice = managed_notices.find(params[:id])
          notice.expire!
          audit("expire_account_notice", notice)
          render json: { notice: notice_json(notice) }
        end

        private

        def managed_notices
          @account.notices.active.announcements
        end

        def notice_json(notice)
          notice.as_management_json.merge(id: notice.to_param)
        end

      end
    end
  end
end
