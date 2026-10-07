# Nonces a runner has already used inside the signature skew window. The
# unique index is the replay check: a second insert of the same nonce fails.
class RunnerRequestNonce < ApplicationRecord

  belongs_to :runner_enrollment

end
