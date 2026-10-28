# A stand-in for Stripe::StripeClient that serves subscriptions from a hash
# and records what was created. Objects are real Stripe::StripeObjects, so
# code under test reads them exactly as it reads Stripe's.
class FakeStripe

  Service = Struct.new(:handlers) do
    def initialize(**handlers) = super(handlers)
    def retrieve(id, *) = handlers.fetch(:retrieve).call(id)
    def create(params = {}, opts = {}) = handlers.fetch(:create).call(params, opts)
    def expire(id, *) = handlers.fetch(:expire).call(id)
    def update(id, params = {}, *) = handlers.fetch(:update).call(id, params)
    def cancel(id, *) = handlers.fetch(:cancel).call(id)
    def search(params = {}, *) = handlers.fetch(:search).call(params)
  end

  attr_reader :created_customers, :checkout_sessions, :portal_sessions, :expired_sessions, :session_states,
    :created_subscriptions, :subscription_updates, :cancelled_subscriptions, :customer_updates

  def initialize
    @subscriptions = {}
    @created_customers = []
    @checkout_sessions = []
    @portal_sessions = []
    @expired_sessions = []
    # Checkout session id => { status:, subscription: }, as Stripe would report it.
    @session_states = {}
    @customers = {}
    @customer_updates = []
    @payment_methods = {}
    @created_subscriptions = []
    @subscription_updates = []
    @cancelled_subscriptions = []
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

  # Search hasn't indexed anything yet (Stripe's search lags by up to a minute).
  def search_lags!
    @search_lags = true
  end

  # The next subscription update raises error and changes nothing.
  def fail_next_subscription_update(error = Stripe::APIConnectionError.new("timed out"))
    @update_fault = error
  end

  def put_subscription(id:, agent:, customer:, price:, status:, period_end: 1.month.from_now, cancel_at_period_end: false)
    @subscriptions[id] = {
      id: id,
      object: "subscription",
      status: status,
      customer: customer,
      cancel_at_period_end: cancel_at_period_end,
      metadata: { agent_id: agent.id.to_s },
      items: { object: "list", data: [ { price: { id: price }, current_period_end: period_end.to_i } ] }
    }
  end

  def v1 = self

  def subscriptions_service
    Service.new(
      retrieve: ->(id) { construct(stored_subscription(id)) },
      create: lambda { |params, opts|
        if (existing = @subscriptions.values.find { |sub| sub[:idempotency_key] && sub[:idempotency_key] == opts[:idempotency_key] })
          # Stripe replays a key only for identical parameters; a replay
          # whose price or card moved is refused, not silently honoured.
          replayed = { items: params[:items].map { |item| item[:price] }, card: params[:default_payment_method] }
          stored = { items: existing[:items][:data].map { |item| item[:price][:id] }, card: existing[:default_payment_method] }
          if replayed != stored
            raise Stripe::IdempotencyError.new("Keys for idempotent requests can only be used with the same parameters they were first used with. #{replayed} vs #{stored}")
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
        @subscriptions[id] = {
          id: id, object: "subscription", status: "incomplete", customer: params[:customer],
          cancel_at_period_end: false, metadata: params[:metadata].transform_keys(&:to_s),
          default_payment_method: params[:default_payment_method], idempotency_key: opts[:idempotency_key],
          items: { object: "list", data: params[:items].map { |item| { price: { id: item[:price] }, current_period_end: 1.month.from_now.to_i } } }
        }
        raise error if error
        construct(with_invoice(@subscriptions[id]))
      },
      search: lambda { |params|
        reference = params[:query][/birth_order'\]:'([0-9a-f-]+)'/, 1]
        found = @search_lags ? [] : @subscriptions.values.select { |sub| sub.dig(:metadata, "birth_order") == reference }
        Stripe::StripeObject.construct_from(object: "search_result", data: found.map(&:deep_dup))
      },
      update: lambda { |id, params|
        if @update_fault
          error = @update_fault
          @update_fault = nil
          raise error
        end
        @subscription_updates << [ id, params ]
        stored = stored_subscription(id)
        stored[:metadata] = stored[:metadata].merge(params[:metadata].transform_keys(&:to_s)) if params[:metadata]
        stored[:default_payment_method] = params[:default_payment_method] if params.key?(:default_payment_method)
        construct(with_invoice(stored))
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
      update: lambda { |id, params|
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
        @checkout_sessions << [ params, opts ]
        id = "cs_test_#{@checkout_sessions.size}"
        @session_states[id] = { status: "open", subscription: nil, mode: params[:mode] || "subscription", customer: params[:customer] }
        Stripe::StripeObject.construct_from(id: id, url: "https://checkout.stripe.com/c/pay/#{id}", client_secret: "#{id}_secret")
      },
      retrieve: lambda { |id|
        Stripe::StripeObject.construct_from({ id: id }.merge(@session_states.fetch(id)))
      },
      expire: lambda { |id|
        raise Stripe::InvalidRequestError.new("Session is not open", "id") unless @session_states.dig(id, :status) == "open"

        @expired_sessions << id
        @session_states[id][:status] = "expired"
      }
    )
    Struct.new(:sessions).new(sessions)
  end

  def billing_portal
    sessions = Service.new(create: lambda { |params, _opts|
      @portal_sessions << params
      Stripe::StripeObject.construct_from(url: "https://billing.stripe.com/p/session/test_1")
    })
    Struct.new(:sessions).new(sessions)
  end

  def subscriptions = subscriptions_service

  private

  def stored_subscription(id)
    @subscriptions.fetch(id) { raise Stripe::InvalidRequestError.new("No such subscription", "id") }
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

    STRIPE_ENV = {
      "STRIPE_SECRET_KEY" => "sk_test_fake", "STRIPE_WEBHOOK_SECRET" => "whsec_test_fake",
      "STRIPE_PRICE_CONVERSATION" => CONVERSATION_PRICE, "STRIPE_PRICE_LIFE" => LIFE_PRICE,
      "STRIPE_PRICE_WORK" => WORK_PRICE,
      "STRIPE_PRICE_CONVERSATION_AT_COST" => CONVERSATION_AT_COST_PRICE, "STRIPE_PRICE_LIFE_AT_COST" => LIFE_AT_COST_PRICE,
      "STRIPE_PRICE_WORK_AT_COST" => WORK_AT_COST_PRICE
    }.freeze

    def self.included(base)
      base.setup do
        @saved_stripe_env = STRIPE_ENV.keys.index_with { |key| ENV[key] }
        ENV.update(STRIPE_ENV)
      end
      base.teardown { @saved_stripe_env.each { |key, value| ENV[key] = value } }
    end

  end

end
