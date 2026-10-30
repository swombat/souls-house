# The house gateway refuses a call it won't fund (HouseInferenceGrant#check!,
# ResidentEntitlement#check_house_call!) and until now recorded nothing: the
# resident's run failed with the gateway's wording in stderr, which the house
# never reads for a category. The gateway now leaves the refusal's code and
# time on the resident, one mark overwritten each time, so a failed run can
# read it by its window. Only allowance refusals are marked: a busy or
# unconfigured gateway is the house's state, not the resident's.
module Agent::HouseRefusals

  extend ActiveSupport::Concern

  MARKED_CODES = %w[house_allowance_exhausted house_allowance_none].freeze

  def note_house_refusal!(error)
    return unless error.respond_to?(:code) && error.code.in?(MARKED_CODES)

    update_columns(house_refusal_code: error.code, house_refused_at: Time.current)
  end

  # Was this resident refused for a spent allowance while the run was going?
  def house_allowance_exhausted_between?(from, to)
    house_refusal_code == "house_allowance_exhausted" && house_refused_at.present? &&
      from.present? && to.present? && house_refused_at.between?(from, to)
  end

end
