# Which offer a subscription item's price was sold at, and what price a new or
# changed item should carry.
#
# Stripe refuses two items with the same price on one subscription (seen in
# test mode on #905, eoXAEj), so an account's shared subscription can't hold
# two residents on the same catalogue price. An item whose offer's catalogue
# price is already taken by a sibling instead gets an inline copy of it
# (price_data on the catalogue price's product: same currency, amount,
# interval and tax behaviour). Stripe makes that a distinct, inactive price.
#
# The item names the catalogue price it copies in its metadata
# (catalogue_price). That name is only a pointer: it says which catalogue
# price to compare against, never what to grant. An inline price is accepted
# only when the catalogue price it names is one of an offer's configured
# prices (current or retired, Billing::Offer#price_ids) and the item's actual
# Stripe price equals it in product, currency, unit amount, interval and
# interval count and tax behaviour, and is a flat, licensed, per-unit
# recurring price with no tiers, custom amount or quantity transform. Anything
# else is a price the house can't vouch for, and SubscriptionSync's untrusted
# path takes it. An amount that merely looks right, on another product or
# under no name, is not enough.
#
# Re-costing an offer adds a new current catalogue price and keeps the old one
# as retired (#619). Stripe prices never change amount, so an inline copy of
# the old price still equals it and still resolves to the same offer and rate;
# at-cost grants are checked on the offer's rate as before.
module Billing
  class ItemPrice

    METADATA_KEY = "catalogue_price"
    COMPARED = %i[product currency unit_amount interval interval_count tax_behavior].freeze

    def initialize(client: Billing.client)
      @client = client
      @catalogue = {}
    end

    # The offer an item was sold at, or nil.
    def offer_for(item)
      problem(item) ? nil : resolve(item)
    end

    # Why the house can't vouch for an item's price, or nil.
    def problem(item)
      id = id_of(item.price)
      return nil if Offer.for_price(id)

      named = metadata(item)[METADATA_KEY].presence
      return "price #{id.inspect} is outside the plan catalogue" unless named
      return "price #{id.inspect} names #{named.inspect}, which is outside the plan catalogue" unless Offer.for_price(named)

      actual = spec(item.price)
      return "price #{id.inspect} is not a flat monthly price" unless flat?(actual)

      expected = catalogue_spec(named)
      return "catalogue price #{named.inspect} is not a flat monthly price" unless flat?(expected)

      differs = COMPARED.reject { |field| actual[field] == expected[field] }
      return "price #{id.inspect} differs from #{named.inspect} in #{differs.join(", ")}" if differs.any?

      nil
    end

    # What an item for offer should carry on remote: the catalogue price, unless
    # another item (other than except_item_id, the one being changed) already
    # uses it; then an inline copy. Either way the item names its catalogue
    # price. The result is deterministic for the same remote, so a request
    # built from it replays byte for byte.
    def item_params(offer, items:, except_item_id: nil)
      catalogue = offer.price_id || raise(NotConfigured, "The #{offer.name} plan has no Stripe price configured")
      taken = items.reject { |item| item.id == except_item_id }.any? { |item| id_of(item.price) == catalogue }
      price = taken ? { price_data: price_data(catalogue) } : { price: catalogue }
      price.merge(metadata: { METADATA_KEY => catalogue })
    end

    private

    def resolve(item)
      Offer.for_price(id_of(item.price)) || Offer.for_price(metadata(item)[METADATA_KEY])
    end

    def price_data(catalogue)
      spec = catalogue_spec(catalogue)
      raise NotConfigured, "Catalogue price #{catalogue} is not a flat monthly price" unless flat?(spec)

      { product: spec[:product], currency: spec[:currency], unit_amount: spec[:unit_amount],
        recurring: { interval: spec[:interval], interval_count: spec[:interval_count] },
        tax_behavior: spec[:tax_behavior] }
    end

    # Catalogue prices are read from Stripe once per instance (one sync or one
    # change): their amounts can't change, and nothing is cached across calls.
    def catalogue_spec(price_id)
      @catalogue[price_id] ||= spec(@client.v1.prices.retrieve(price_id))
    end

    def spec(price)
      recurring = price[:recurring] || {}
      { product: id_of(price[:product]), currency: price[:currency], unit_amount: price[:unit_amount],
        interval: recurring[:interval], interval_count: recurring[:interval_count], usage_type: recurring[:usage_type],
        tax_behavior: price[:tax_behavior], type: price[:type], billing_scheme: price[:billing_scheme],
        tiers_mode: price[:tiers_mode], transform_quantity: price[:transform_quantity],
        custom_unit_amount: price[:custom_unit_amount] }
    end

    def flat?(spec)
      spec[:type] == "recurring" && spec[:billing_scheme] == "per_unit" && spec[:usage_type] == "licensed" &&
        spec[:tiers_mode].nil? && spec[:transform_quantity].nil? && spec[:custom_unit_amount].nil? &&
        spec[:unit_amount].is_a?(Integer) && spec[:product].present? && spec[:currency].present? &&
        spec[:interval].present? && spec[:interval_count].is_a?(Integer)
    end

    def metadata(item)
      (item[:metadata] || {}).to_h.transform_keys(&:to_s)
    end

    def id_of(value)
      value.respond_to?(:id) ? value.id : value
    end

  end
end
