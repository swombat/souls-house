# Account portability: one ZIP holding an account's residents (each in its
# own unchanged resident archive), its Field and its setup, and the import
# that rebuilds them in another account. docs/features/account-portability.md
module Accounts::Portability
  class Error < StandardError; end
end
