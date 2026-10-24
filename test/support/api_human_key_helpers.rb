# Keys for the human-key /api/v1 tests: a person's key, a resident's key, and
# the person losing their membership.
module ApiHumanKeyHelpers

  def human_headers(user, account)
    key = ApiKey.generate_for(user, name: "Human key tests", account: account)
    { "Authorization" => "Bearer #{key.raw_token}" }
  end

  # One key per resident (a unique index), so it's made once per test.
  def resident_headers(user, agent)
    @resident_headers ||= {}
    @resident_headers[agent.id] ||= begin
      key = ApiKey.generate_for(user, name: "Resident key tests", agent: agent)
      { "Authorization" => "Bearer #{key.raw_token}" }
    end
  end

  def end_membership!(user, account)
    account.memberships.find_by!(user: user).update_columns(confirmed_at: nil)
  end

end
