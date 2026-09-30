class HouseInferenceGrant < ApplicationRecord

  MONTHLY_LIMIT = BigDecimal('10')
  belongs_to :user
  belongs_to :agent, optional: true
  has_many :house_inference_calls, dependent: :restrict_with_error
  validates :user_id, uniqueness: true
  validates :agent_id, uniqueness: true, allow_nil: true

  # One short global transaction lock also serializes new grants and the global
  # subsidy ceiling. No network I/O is performed while holding it.
  def self.synchronize
    transaction do
      connection.execute('SELECT pg_advisory_xact_lock(184732, 1)')
      yield
    end
  end

  def self.assign!(agent, user)
    synchronize do
      grant = find_by(agent: agent)
      if HouseInference::Offering.find(agent.model_id)
        return grant if grant
        unless agent.account.ai_credentials_manageable_by?(user)
          agent.errors.add(:model_id, 'requires permission to manage account credentials')
          raise ActiveRecord::RecordInvalid, agent
        end
        grant ||= find_or_initialize_by(user: user)
        if grant.agent_id && grant.agent_id != agent.id
          agent.errors.add(:model_id, 'only one on-the-house resident is allowed per user across all accounts; switch the other resident to personal funding first')
          raise ActiveRecord::RecordInvalid, agent
        end
        grant.update!(agent: agent)
      elsif grant
        grant.update!(agent: nil)
      end
      grant
    end
  end

  def spent(month = HouseInference::Offering.month)
    house_inference_calls.where(month: month).sum(:charge_usd)
  end

  def reserve!(offering, model_id, agent_id: self.agent_id)
    self.class.synchronize do
      reload
      unless self.agent_id == agent_id
        raise HouseInference::Error.new('The house allowance has moved to another resident.', status: 403)
      end
      check!(model_id)
      month = HouseInference::Offering.month
      house_inference_calls.create!(month: month, model_id: model_id,
        provider_route: offering.fetch(:provider), charge_usd: offering.fetch(:reservation_usd))
    end
  end

  def check!(model_id)
    raise HouseInference::Error.new('House inference has not been configured by the operator.') unless HouseInference::Offering.configured?
    if HouseInferenceCall.where(status: 'overrun').exists?
      raise HouseInference::Error.new('House inference is paused pending a billing review.')
    end
    unless agent && agent.model_id == model_id && agent.active? && !agent.account.disabled? && user.memberships.confirmed.exists?(account_id: agent.account_id)
      raise HouseInference::Error.new('This resident has no active house allowance.', status: 403)
    end
    if house_inference_calls.where(status: 'pending').exists?
      raise HouseInference::Error.new('A house-funded call is already in progress. Try again shortly.', code: 'house_inference_busy', status: 429)
    end
    month = HouseInference::Offering.month
    if spent(month) >= MONTHLY_LIMIT
      raise HouseInference::Error.new('The $10 house allowance is used up. It resets at the start of next month (UTC).', code: 'house_allowance_exhausted', status: 402)
    end
    if HouseInferenceCall.where(month: month).sum(:charge_usd) >= HouseInference::Offering.global_limit
      raise HouseInference::Error.new('The house-wide inference allowance is currently used up.', code: 'house_allowance_unavailable', status: 503)
    end
  end

  def presentation
    month = HouseInference::Offering.month
    used = spent(month)
    { limit_usd: MONTHLY_LIMIT.to_f, used_usd: used.to_f,
      remaining_usd: [ MONTHLY_LIMIT - used, 0 ].max.to_f,
      resets_at: month.next_month.iso8601, configured: HouseInference::Offering.configured? }
  end

end
