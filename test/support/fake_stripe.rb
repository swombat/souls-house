# A stand-in for Stripe::StripeClient that serves subscriptions from a hash
# and records what was created. Objects are real Stripe::StripeObjects, so
# code under test reads them exactly as it reads Stripe's.
class FakeStripe

  Service = Struct.new(:handlers) do
    def initialize(**handlers) = super(handlers)
    def retrieve(id, *) = handlers.fetch(:retrieve).call(id)
    def create(params = {}, opts = {}) = handlers.fetch(:create).call(params, opts)
    def expire(id, *) = handlers.fetch(:expire).call(id)
    def update(id, params = {}, opts = {}, *) = handlers.fetch(:update).call(id, params, opts)
    def cancel(id, *) = handlers.fetch(:cancel).call(id)
    def search(params = {}, *) = handlers.fetch(:search).call(params)
    def list(params = {}, *) = handlers.fetch(:list).call(params)
  end

  attr_reader :created_customers, :checkout_sessions, :portal_sessions, :expired_sessions, :session_states,
    :created_subscriptions, :subscription_updates, :cancelled_subscriptions, :customer_updates

  def initialize
    @subscriptions = {}
    @created_customers = []
    @checkout_sessions = []
    @portal_sessions = []
    @portal_configurations = []
    @expired_sessions = []
    # Checkout session id => { status:, subscription: }, as Stripe would report it.
    @session_states = {}
    @customers = {}
    @customer_updates = []
    @payment_methods = {}
    @created_subscriptions = []
    @subscription_updates = []
    @update_responses = {}
    @update_params = {}
    @cancelled_subscriptions = []
    @prices = {}
    @inline_prices = 0
    Helpers::CATALOGUE.each { |id, (product, amount)| put_price(id, product: product, unit_amount: amount) }
  end

  # A catalogue price as Stripe would serve it: flat, licensed, monthly.
  # Overrides make the shapes the house must refuse (tiered, another
  # product, a different tax behaviour...).
  def put_price(id, product: "prod_test_other", unit_amount: 1000, **overrides)
    @prices[id] = { id: id, object: "price", active: true, type: "recurring", billing_scheme: "per_unit",
                    product: product, currency: "usd", unit_amount: unit_amount, tax_behavior: "exclusive",
                    recurring: { interval: "month", interval_count: 1, usage_type: "licensed" },
                    tiers_mode: nil, transform_quantity: nil, custom_unit_amount: nil }.deep_merge(overrides)
  end

  # What Stripe makes from an item's price_data: a new, inactive price.
  def create_inline_price(data)
    @inline_prices += 1
    put_price("price_inline_#{@inline_prices}", product: data.fetch(:product), unit_amount: data.fetch(:unit_amount),
      active: false, currency: data.fetch(:currency), tax_behavior: data[:tax_behavior] || "unspecified",
      recurring: { interval: data.dig(:recurring, :interval), interval_count: data.dig(:recurring, :interval_count) || 1 })
  end

  # An inline copy of a catalogue price, as the house would have Stripe make
  # it, with overrides for copies the house must not accept.
  def inline_price(catalogue, **overrides)
    source = @prices.fetch(catalogue)
    price = create_inline_price(product: source[:product], unit_amount: source[:unit_amount], currency: source[:currency],
      tax_behavior: source[:tax_behavior], recurring: source[:recurring].slice(:interval, :interval_count))
    price.deep_merge!(overrides)
  end

  def price_object(id)
    @prices.fetch(id) { put_price(id, product: "prod_test_unknown") }
  end

  def prices
    Service.new(retrieve: lambda { |id|
      raise Stripe::InvalidRequestError.new("No such price: '#{id}'", "id") unless @prices.key?(id)

      construct(@prices[id])
    })
  end

  # A card Stripe would hold for a customer, by payment method id.
  def put_payment_method(id, brand: "visa", last4: "4242", exp_month: 10, exp_year: 2030)
    @payment_methods[id] = { id: id, object: "payment_method",
      card: { brand: brand, last4: last4, exp_month: exp_month, exp_year: exp_year } }
  end

  # A customer's default card, as invoice_settings.default_payment_method.
  def put_customer(id, default_payment_method: nil)
    @customers[id] = { id: id, object: "customer", invoice_settings: { default_payment_method: default_payment_method } }
  end

  # What a finished embedded card form reports when re-read.
  def complete_setup_session(id, payment_method:)
    @session_states[id] = @session_states.fetch(id).merge(status: "complete", setup_intent: { payment_method: payment_method })
  end

  # A subscription-mode Checkout session is completed by the customer: Stripe
  # makes its subscription from the session's subscription_data, trialing if
  # it asked for a trial (no card needed), and reports the session complete.
  def complete_checkout_session(id, subscription_id:, trial_end: 14.days.from_now)
    state = @session_states.fetch(id)
    params = state.fetch(:create_params)
    data = params[:subscription_data] || {}
    trial = data[:trial_period_days].present?
    @subscriptions[subscription_id] = {
      id: subscription_id, object: "subscription", status: trial ? "trialing" : "active", customer: params[:customer],
      cancel_at_period_end: false, metadata: (data[:metadata] || {}).transform_keys(&:to_s),
      trial_end: trial ? trial_end.to_i : nil, default_payment_method: nil,
      items: { object: "list", data: params[:line_items].each_with_index.map { |item, index|
        { id: "si_#{subscription_id}_#{index}", price: price_object(item[:price]), quantity: item[:quantity] || 1,
          current_period_end: trial_end.to_i }
      } }
    }
    @session_states[id] = state.merge(status: "complete", subscription: subscription_id)
  end

  # The first invoice of a subscription is paid (or not).
  def set_subscription_status(id, status)
    @subscriptions.fetch(id)[:status] = status
  end

  def subscription(id) = @subscriptions.fetch(id)

  # Fault injection. The next subscription create raises error; with
  # created: true Stripe made the subscription anyway (a lost response).
  def fail_next_subscription_create(error = Stripe::APIConnectionError.new("timed out"), created: true)
    @create_fault = [ error, created ]
  end

  # The next Checkout session create has no certain answer: Stripe made the
  # session (created: true) or didn't, and the caller sees only the error.
  def fail_next_checkout_create(error = Stripe::APIConnectionError.new("timed out"), created: true)
    @checkout_fault = [ error, created ]
  end

  # Search hasn't indexed anything yet (Stripe's search lags by up to a minute).
  def search_lags!
    @search_lags = true
  end

  # The next subscription update raises error. It changes nothing, unless
  # applied: Stripe made the change and only the answer was lost.
  def fail_next_subscription_update(error = Stripe::APIConnectionError.new("timed out"), applied: false)
    @update_fault = error
    @update_fault_applied = applied
  end

  def put_subscription(id:, agent:, customer:, price:, status:, period_end: 1.month.from_now, cancel_at_period_end: false,
    trial_end: nil)
    @subscriptions[id] = {
      trial_end: trial_end&.to_i,
      id: id,
      object: "subscription",
      status: status,
      customer: customer,
      cancel_at_period_end: cancel_at_period_end,
      metadata: { agent_id: agent.id.to_s },
      items: { object: "list", data: [ { id: "si_#{id}", price: price_object(price), quantity: 1, current_period_end: period_end.to_i } ] }
    }
  end

  # An account's one subscription, one item per resident. items: hashes of
  # agent:, and price: (a price id, or a price hash from inline_price), and
  # optionally id:, quantity:, metadata: (merged over the item's agent_id).
  # page_size: serve items in pages of this size, the rest through
  # subscription_items.list, as Stripe does past its embedded page. Stripe
  # can't hold one price on two items, so neither can this.
  def put_shared_subscription(id:, account:, customer:, status:, items:, period_end: 1.month.from_now, page_size: nil,
    trial_end: nil, metadata: {})
    data = items.each_with_index.map do |item, index|
      meta = item[:agent] ? { "agent_id" => item[:agent].id.to_s } : {}
      price = item.fetch(:price)
      { id: item[:id] || "si_#{id}_#{index}", price: price.is_a?(Hash) ? price : price_object(price), quantity: item.fetch(:quantity, 1),
        metadata: meta.merge((item[:metadata] || {}).transform_keys(&:to_s)), current_period_end: period_end.to_i }
    end
    refuse_shared_price!(data)
    @subscriptions[id] = {
      id: id, object: "subscription", status: status, customer: customer, cancel_at_period_end: false,
      trial_end: trial_end&.to_i,
      metadata: { "kind" => "account", "account_id" => account.id.to_s }.merge(metadata.transform_keys(&:to_s)),
      items: { object: "list", data: page_size ? data.first(page_size) : data, has_more: page_size ? data.size > page_size : false },
      all_items: data
    }
  end

  def subscription_items
    Service.new(list: lambda { |params|
      all = stored_subscription(params[:subscription])[:all_items] || stored_subscription(params[:subscription])[:items][:data]
      from = params[:starting_after] ? all.index { |row| row[:id] == params[:starting_after] } + 1 : 0
      size = [ params[:limit] || 100, @subscription_item_page_size || 100 ].min
      page = all[from, size] || []
      construct(object: "list", data: page, has_more: from + size < all.size)
    })
  end

  def subscription_item_page_size!(size) = @subscription_item_page_size = size

  # A subscription for an account's plan (Billing::AccountPlanCheckout's metadata).
  def put_account_subscription(id:, account:, customer:, price:, status:, period_end: 1.month.from_now,
    cancel_at_period_end: false)
    @subscriptions[id] = {
      id: id,
      object: "subscription",
      status: status,
      customer: customer,
      cancel_at_period_end: cancel_at_period_end,
      metadata: { "kind" => "account_plan", "account_id" => account.id.to_s },
      items: { object: "list", data: [ { id: "si_#{id}", price: price_object(price), quantity: 1, current_period_end: period_end.to_i } ] }
    }
  end

  def v1 = self

  def subscriptions_service
    Service.new(
      retrieve: ->(id) { construct(stored_subscription(id)) },
      create: lambda { |params, opts|
        if (existing = @subscriptions.values.find { |sub| sub[:idempotency_key] && sub[:idempotency_key] == opts[:idempotency_key] })
          # Stripe replays a key only for identical parameters; a replay
          # whose payload moved in any way is refused, not silently honoured.
          if params.except(:expand) != existing[:create_params]
            raise Stripe::IdempotencyError.new("Keys for idempotent requests can only be used with the same parameters they " \
                                               "were first used with. #{params.except(:expand)} vs #{existing[:create_params]}")
          end
          next construct(with_invoice(existing))
        end
        if @create_fault
          error, created = @create_fault
          @create_fault = nil
          raise error unless created
        end
        @created_subscriptions << [ params, opts ]
        id = "sub_new_#{@created_subscriptions.size}"
        items = params[:items].each_with_index.map { |item, index| { id: "si_#{id}_#{index}", price: price_object(item[:price]), quantity: item[:quantity] || 1, current_period_end: 1.month.from_now.to_i } }
        refuse_shared_price!(items)
        @subscriptions[id] = {
          id: id, object: "subscription", status: "incomplete", customer: params[:customer],
          cancel_at_period_end: false, metadata: params[:metadata].transform_keys(&:to_s),
          default_payment_method: params[:default_payment_method], idempotency_key: opts[:idempotency_key],
          create_params: params.except(:expand).deep_dup,
          items: { object: "list", data: items }
        }
        raise error if error
        construct(with_invoice(@subscriptions[id]))
      },
      search: lambda { |params|
        reference = params[:query][/birth_order'\]:'([0-9a-f-]+)'/, 1]
        found = @search_lags ? [] : @subscriptions.values.select { |sub| sub.dig(:metadata, "birth_order") == reference }
        Stripe::StripeObject.construct_from(object: "search_result", data: found.map(&:deep_dup))
      },
      update: lambda { |id, params, opts = {}|
        lost = nil
        if @update_fault
          error = @update_fault
          @update_fault = nil
          raise error unless @update_fault_applied

          lost = error
        end
        # Stripe replays an idempotency key, for the same parameters only: the
        # cached response, no mutation.
        if (key = opts[:idempotency_key]) && (cached = @update_responses[key])
          unless @update_params[key] == [ id, params ]
            raise Stripe::IdempotencyError.new("Keys for idempotent requests can only be used with the same parameters they " \
              "were first used with.")
          end
          @subscription_updates << [ id, params, opts.merge(replayed: true) ]
          next cached
        end
        @subscription_updates << [ id, params, opts ]
        stored = stored_subscription(id)
        # Stripe validates the whole request before changing anything: a
        # change that would put one price on two items fails and leaves the
        # subscription as it was.
        planned = (stored[:all_items] || stored[:items][:data]).map(&:deep_dup)
        shown = stored[:items][:data].size
        Array(params[:items]).each do |change|
          if change[:id].nil?
            # A new item, as Billing::AddItem adds a resident.
            planned << { id: "si_#{id}_added_#{planned.size}", quantity: change[:quantity] || 1,
                         price: change[:price_data] ? { price_data: change[:price_data] } : { id: change[:price] },
                         metadata: (change[:metadata] || {}).transform_keys(&:to_s),
                         current_period_end: planned.first&.dig(:current_period_end) || 1.month.from_now.to_i }
            shown += 1 unless stored[:items][:has_more]
            next
          end
          item = planned.find { |row| row[:id] == change[:id] } ||
            raise(Stripe::InvalidRequestError.new("No such subscription item: #{change[:id]}", "items"))
          if change[:deleted]
            # Billing::EndItem: the item goes; its unused time is a
            # proration credit waiting for the next invoice.
            planned.delete(item)
            shown -= 1
            put_pending_invoice_item(stored[:customer], -(@proration_amount || 500)) if params[:proration_behavior] == "create_prorations"
            next
          end
          item[:price] = { id: change[:price] } if change[:price]
          item[:price] = { price_data: change[:price_data] } if change[:price_data]
          item[:metadata] = (item[:metadata] || {}).merge(change[:metadata].transform_keys(&:to_s)) if change[:metadata]
        end
        refuse_shared_price!(planned)
        planned.each do |item|
          item[:price] = create_inline_price(item[:price][:price_data]) if item[:price].key?(:price_data)
          item[:price] = price_object(item[:price][:id]) unless item[:price].key?(:object)
        end
        stored[:items][:data] = planned.first(shown)
        stored[:all_items] = planned if stored.key?(:all_items)
        stored[:metadata] = stored[:metadata].merge(params[:metadata].transform_keys(&:to_s)) if params[:metadata]
        stored[:default_payment_method] = params[:default_payment_method] if params.key?(:default_payment_method)
        stored[:description] = params[:description] if params.key?(:description)
        if params.key?(:cancel_at_period_end)
          # As Stripe does, cancel_at follows: the period's end, or nothing.
          stored[:cancel_at_period_end] = params[:cancel_at_period_end]
          stored[:cancel_at] = params[:cancel_at_period_end] ? stored[:items][:data].first&.dig(:current_period_end) : nil
        end
        response = construct(with_invoice(stored))
        if opts[:idempotency_key]
          @update_responses[opts[:idempotency_key]] = response
          @update_params[opts[:idempotency_key]] = [ id, params.deep_dup ]
        end
        raise lost if lost

        response
      },
      cancel: lambda { |id|
        @cancelled_subscriptions << id
        stored_subscription(id)[:status] = "canceled"
        construct(stored_subscription(id))
      }
    )
  end

  def customers
    Service.new(
      create: lambda { |params, opts|
        @created_customers << [ params, opts ]
        id = "cus_test_#{@created_customers.size}"
        put_customer(id)
        Stripe::StripeObject.construct_from(id: id)
      },
      retrieve: lambda { |id|
        customer = @customers.fetch(id) { put_customer(id) }
        method = customer.dig(:invoice_settings, :default_payment_method)
        construct(customer.merge(invoice_settings: { default_payment_method: method && @payment_methods.fetch(method) }))
      },
      update: lambda { |id, params, _opts = {}|
        @customer_updates << [ id, params ]
        customer = @customers.fetch(id) { put_customer(id) }
        if (method = params.dig(:invoice_settings, :default_payment_method))
          put_payment_method(method) unless @payment_methods.key?(method)
          customer[:invoice_settings] = { default_payment_method: method }
        end
        construct(customer)
      }
    )
  end

  def checkout
    sessions = Service.new(
      create: lambda { |params, opts|
        # Stripe replays an idempotency key only for identical parameters.
        if (replayed = @session_states.find { |_id, state| state[:idempotency_key] && state[:idempotency_key] == opts[:idempotency_key] })
          id, state = replayed
          if params != state[:create_params]
            raise Stripe::IdempotencyError.new("Keys for idempotent requests can only be used with the same parameters they " \
                                               "were first used with. #{params} vs #{state[:create_params]}")
          end
          next construct({ id: id, url: "https://checkout.stripe.com/c/pay/#{id}", client_secret: "#{id}_secret" }.merge(state))
        end
        fault = @checkout_fault
        @checkout_fault = nil
        raise fault[0] if fault && !fault[1]
        @checkout_sessions << [ params, opts ]
        id = "cs_test_#{@checkout_sessions.size}"
        @session_states[id] = { status: "open", subscription: nil, mode: params[:mode] || "subscription", customer: params[:customer],
                                client_reference_id: params[:client_reference_id],
                                metadata: params[:metadata]&.transform_keys(&:to_s) || {},
                                url: "https://checkout.stripe.com/c/pay/#{id}",
                                idempotency_key: opts[:idempotency_key], create_params: params.deep_dup }
        raise fault[0] if fault
        Stripe::StripeObject.construct_from(id: id, url: "https://checkout.stripe.com/c/pay/#{id}", client_secret: "#{id}_secret")
      },
      retrieve: lambda { |id|
        Stripe::StripeObject.construct_from({ id: id }.merge(@session_states.fetch(id)))
      },
      expire: lambda { |id|
        raise Stripe::InvalidRequestError.new("Session is not open", "id") unless @session_states.dig(id, :status) == "open"

        @expired_sessions << id
        @session_states[id][:status] = "expired"
        construct({ id: id }.merge(@session_states[id]))
      },
      list: lambda { |params|
        all = @session_states.select { |_id, state| state[:customer] == params[:customer] }.to_a
        from = params[:starting_after] ? all.index { |id, _state| id == params[:starting_after] } + 1 : 0
        size = params[:limit] || 100
        page = all[from, size] || []
        construct(object: "list", data: page.map { |id, state| { id: id }.merge(state) }, has_more: from + size < all.size)
      }
    )
    Struct.new(:sessions).new(sessions)
  end

  def billing_portal
    sessions = Service.new(create: lambda { |params, _opts|
      @portal_sessions << params
      Stripe::StripeObject.construct_from(url: "https://billing.stripe.com/p/session/test_1")
    })
    configurations = Service.new(list: lambda { |params|
      all = @portal_configurations
      from = params[:starting_after] ? all.index { |row| row[:id] == params[:starting_after] } + 1 : 0
      size = @portal_page_size || params[:limit] || 100
      page = all[from, size] || []
      Stripe::StripeObject.construct_from(object: "list", data: page.map(&:deep_dup), has_more: from + size < all.size)
    })
    Struct.new(:sessions, :configurations).new(sessions, configurations)
  end

  # A portal configuration whose plan switcher offers these prices (none by
  # default: the house's portal lets nobody switch plans). allowed: what the
  # switcher may change; products: nil for a plan list Stripe didn't send.
  def put_portal_configuration(prices: [], active: true, enabled: true, allowed: %w[price quantity], products: :from_prices,
    card_update: true, cancel: true, invoices: true)
    product_list = products == :from_prices ? (prices.empty? ? [] : [ { product: "prod_test", prices: prices } ]) : products
    update = { enabled: enabled, default_allowed_updates: allowed }.compact
    update[:products] = product_list unless product_list.nil?
    # A flag given as nil is one Stripe didn't send.
    features = { subscription_update: update, subscription_cancel: { enabled: cancel }.compact,
                 payment_method_update: { enabled: card_update }, invoice_history: { enabled: invoices } }
    @portal_configurations << {
      id: "bpc_test_#{@portal_configurations.size + 1}", active: active, is_default: @portal_configurations.empty?,
      features: features
    }
  end

  # Pages of this size from configurations.list, to test pagination.
  def portal_page_size!(size) = @portal_page_size = size

  def subscriptions = subscriptions_service

  # What a price costs a month, in cents, for invoice previews, where a test
  # overrides the price's own unit amount.
  def price_amounts = (@price_amounts ||= {})

  # The part-period a preview charges for an added item, in cents.
  attr_writer :proration_amount

  # Invoice-level effects a preview totals in: a tax rate (percent, on the
  # whole invoice) and an amount off each invoice.
  attr_writer :tax_percent, :amount_off

  # How many lines a preview embeds before has_more (Stripe: 10).
  attr_writer :preview_line_page

  attr_reader :previews

  # A one-off charge waiting for the customer's next invoice.
  def put_pending_invoice_item(customer, amount)
    (@pending_items ||= Hash.new { |hash, key| hash[key] = [] })[customer] << amount
  end

  # Stripe's preview of an invoice if the subscription took these items.
  # preview_mode "next" (the default): next period's charge for every item,
  # a proration line for each item being added, and pending one-off charges.
  # "recurring": a period's charge alone; like Stripe, it refuses prorations.
  def invoices
    Invoices.new(self)
  end

  Invoices = Struct.new(:fake) do
    def create_preview(params = {}, *) = fake.send(:preview_invoice, params)
  end

  private

  def preview_invoice(params)
    (@previews ||= []) << params.deep_dup
    stored = stored_subscription(params[:subscription])
    details = params[:subscription_details] || {}
    recurring = params[:preview_mode] == "recurring"
    if recurring && details[:items] && details[:proration_behavior] != "none"
      raise Stripe::InvalidRequestError.new("Recurring estimates do not support the following features: subscription prorations, " \
        "trials, cancellations, prebilling, schedules, and invoice item additions.", "preview_mode")
    end

    items = (stored[:all_items] || stored[:items][:data]).map(&:deep_dup)
    added = []
    credits = []
    if details[:cancel_at_period_end]
      # The invoice at the period's end when the subscription won't renew:
      # only charges already waiting.
      lines = Array(@pending_items&.dig(params[:customer])).map { |pending| { amount: pending, proration: false } }
      return construct(object: "invoice", currency: "usd", subtotal: lines.sum { |line| line[:amount] },
        total: lines.sum { |line| line[:amount] }, next_payment_attempt: (stored[:items][:data].first || {})[:current_period_end],
        lines: { object: "list", data: lines, has_more: false })
    end
    Array(details[:items]).each do |change|
      if change[:deleted]
        items.reject! { |item| item[:id] == change[:id] }
        credits << { amount: -(@proration_amount || 500), proration: true } if details[:proration_behavior] == "create_prorations"
        next
      end
      price = if change[:price_data]
        { id: "price_preview", unit_amount: change[:price_data][:unit_amount] }
      elsif change[:price]
        price_object(change[:price])
      end
      if change[:id].nil?
        added << { price: price }
      elsif price
        items.find { |item| item[:id] == change[:id] }[:price] = price
      end
    end
    refuse_shared_price!((items + added).reject { |item| item[:price][:id] == "price_preview" })
    amount = ->(price) { price_amounts.fetch(price[:id]) { price[:unit_amount] } }
    lines = (items + added).map { |item| { amount: amount.(item[:price]), proration: false } }
    unless recurring
      lines += added.map { { amount: @proration_amount || 500, proration: true } } if details[:proration_behavior] == "create_prorations"
      lines += credits
      lines += Array(@pending_items&.dig(params[:customer])).map { |pending| { amount: pending, proration: false } }
    end
    subtotal = lines.sum { |line| line[:amount] }
    discounted = [ subtotal - (@amount_off || 0), 0 ].max
    tax = (discounted * (@tax_percent || 0) / 100.0).round
    construct(object: "invoice", currency: "usd", subtotal: subtotal, total: discounted + tax,
      next_payment_attempt: (stored[:items][:data].first || {})[:current_period_end],
      lines: { object: "list", data: lines.first(@preview_line_page || 10), has_more: lines.size > (@preview_line_page || 10) })
  end

  def stored_subscription(id)
    @subscriptions.fetch(id) { raise Stripe::InvalidRequestError.new("No such subscription", "id") }
  end

  # Stripe's own refusal, word for word in its essentials.
  def refuse_shared_price!(items)
    ids = items.filter_map { |item| item[:price][:id] }
    duplicate = ids.find { |id| ids.count(id) > 1 }
    return unless duplicate

    raise Stripe::InvalidRequestError.new("A new item with Price #{duplicate} can't be added to this Subscription because " \
      "an existing Subscription Item is already using that Price.", "items")
  end

  def with_invoice(subscription)
    subscription.merge(latest_invoice: { id: "in_#{subscription[:id]}", status: "open",
      confirmation_secret: { type: "payment_intent", client_secret: "pi_#{subscription[:id]}_secret" } })
  end

  def construct(hash) = Stripe::StripeObject.construct_from(hash.deep_dup)

  public

  module Helpers

    CONVERSATION_PRICE = "price_test_conversation".freeze
    LIFE_PRICE = "price_test_life".freeze
    WORK_PRICE = "price_test_work".freeze
    CONVERSATION_AT_COST_PRICE = "price_test_conversation_at_cost".freeze
    LIFE_AT_COST_PRICE = "price_test_life_at_cost".freeze
    WORK_AT_COST_PRICE = "price_test_work_at_cost".freeze
    PARTNERS_PRICE = "price_test_account_partners".freeze
    COLLEAGUES_PRICE = "price_test_account_colleagues".freeze

    # Catalogue prices as Stripe holds them: price id => [product, unit amount].
    # A tier's standard and at-cost prices share its product.
    CATALOGUE = {
      CONVERSATION_PRICE => [ "prod_test_conversation", 2499 ], LIFE_PRICE => [ "prod_test_life", 4999 ],
      WORK_PRICE => [ "prod_test_work", 9999 ], CONVERSATION_AT_COST_PRICE => [ "prod_test_conversation", 999 ],
      LIFE_AT_COST_PRICE => [ "prod_test_life", 1999 ], WORK_AT_COST_PRICE => [ "prod_test_work", 3999 ],
      PARTNERS_PRICE => [ "prod_test_partners", 1999 ], COLLEAGUES_PRICE => [ "prod_test_colleagues", 4999 ]
    }.freeze

    STRIPE_ENV = {
      "STRIPE_SECRET_KEY" => "sk_test_fake", "STRIPE_WEBHOOK_SECRET" => "whsec_test_fake",
      "STRIPE_PRICE_CONVERSATION" => CONVERSATION_PRICE, "STRIPE_PRICE_LIFE" => LIFE_PRICE,
      "STRIPE_PRICE_WORK" => WORK_PRICE,
      "STRIPE_PRICE_CONVERSATION_AT_COST" => CONVERSATION_AT_COST_PRICE, "STRIPE_PRICE_LIFE_AT_COST" => LIFE_AT_COST_PRICE,
      "STRIPE_PRICE_WORK_AT_COST" => WORK_AT_COST_PRICE,
      "STRIPE_PRICE_ACCOUNT_PARTNERS" => PARTNERS_PRICE, "STRIPE_PRICE_ACCOUNT_COLLEAGUES" => COLLEAGUES_PRICE
    }.freeze

    def self.included(base)
      base.setup do
        @saved_stripe_env = STRIPE_ENV.keys.index_with { |key| ENV[key] }
        ENV.update(STRIPE_ENV)
        # The account's resident-billing session lock can't be taken inside
        # the fixture transaction; unit contracts run as its holder. The key
        # itself is CheckoutLockTest's and SharedSubscriptionSyncTest's.
        @saved_residents_lock = Billing::CheckoutLock.method(:synchronize_residents)
        Billing::CheckoutLock.define_singleton_method(:synchronize_residents) { |_account, &operation| operation.call }
      end
      base.teardown do
        @saved_stripe_env.each { |key, value| ENV[key] = value }
        saved = @saved_residents_lock
        Billing::CheckoutLock.define_singleton_method(:synchronize_residents, saved) if saved
      end
    end

  end

end
