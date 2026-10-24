# Nonces the comms connector has already used for a connection inside the
# signature window. The unique index is the replay check: a second insert of
# the same nonce fails. Mirrors RunnerRequestNonce.
class CommsRequestNonce < ApplicationRecord

  belongs_to :service_connection

end
