module Billing
  # Changes to an account's bill that were sent to Stripe and whose outcome
  # the house hasn't settled yet (Mira, #909 emmNyb). An add and an end must
  # never both be in that state: an end chosen while an add might still land
  # can cancel a bill that is about to carry two residents, and an end
  # replayed after an add has landed would end both. So, under the account's
  # lock, neither is sent for the first time while the other kind is
  # unsettled; the sweep settles it, and the owner tries again. Replays of
  # something already sent need no check: the two can't coexist.
  module BillInFlight

    ADD_WAITING = "Another change to this account's bill is still being confirmed with Stripe. " \
                  "Try again in a few minutes; nothing was changed.".freeze
    END_WAITING = "A plan on this account's bill is still being ended with Stripe. " \
                  "Try again in a few minutes; nothing was added.".freeze

    module_function

    # Sent end attempts with no settled outcome, other than `except`.
    def ends(account, except: nil)
      scope = BillingCheckoutAttempt.unresolved.where(account: account, kind: EndItem::KIND).where.not(submitted_at: nil)
      except ? scope.where.not(id: except.id) : scope
    end

    # Sent adds (AddItem attempts, paid-birth item orders) with no item at
    # Stripe naming them yet. `items` are the parent's items, as read.
    def adds(account, items)
      meta = items.map { |item| (item[:metadata] || {}).to_h.transform_keys(&:to_s) }
      attempts = BillingCheckoutAttempt.unresolved.where(account: account, kind: AddItem::KIND).where.not(submitted_at: nil)
        .reject { |attempt| meta.any? { |row| row["checkout_attempt"] == attempt.idempotency_key } }
      orders = ResidentBirthOrder.where(account: account, kind: "item", state: %w[pending failed], stripe_subscription_item_id: nil)
        .where.not(item_submitted_at: nil)
        .reject { |order| meta.any? { |row| row["birth_order"] == order.reference } }
      attempts + orders
    end

    def refuse_add!(account)
      raise NotReady, END_WAITING if ends(account).exists?
    end

    def refuse_end!(account, items, except: nil)
      raise NotReady, ADD_WAITING if ends(account, except: except).exists? || adds(account, items).any?
    end

  end
end
