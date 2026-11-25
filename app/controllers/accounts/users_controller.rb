class Accounts::UsersController < ApplicationController

  def show
    render inertia: "accounts/users", props: {
      account: current_account,
      members: -> { account_members_json },
      can_manage: current_account.manageable_by?(Current.user),
      can_invite_owner: current_account.owned_by?(Current.user),
      current_user_id: Current.user.id
    }
  end

  private

  def account_members_json
    return [] if current_account.personal?

    current_account.members_with_details.map { |member| member.as_json(current_user: Current.user) }
  end

end
