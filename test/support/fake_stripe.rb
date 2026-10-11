# A stand-in for Stripe::StripeClient that serves subscriptions from a hash
# and records what was created. Objects are real Stripe::StripeObjects, so
# code under test reads them exactly as it reads Stripe's.
class FakeStripe

  Service = Struct.new(:handlers) do
    def initialize(**handlers) = super(handlers)
    def retrieve(id, *) = handlers.fetch(:retrieve).call(id)
    def create(params = {}, opts = {}) = handlers.fetch(:create).call(params, opts)
    def expire(id, *) = handlers.fetch(:expire).call(id)
  end

  attr_reader :created_customers, :checkout_sessions, :portal_sessions, :expired_sessions, :session_states

  def initialize
    @subscriptions = {}
    @created_customers = []
    @checkout_sessions = []
    @portal_sessions = []
    @expired_sessions = []
    # Checkout session id => { status:, subscription: }, as Stripe would report it.
    @session_states = {}
  end

  def put_subscription(id:, agent:, customer:, price:, status:, period_end: 1.month.from_now, cancel_at_period_end: false)
    @subscriptions[id] = Stripe::StripeObject.construct_from(
      id: id,
      object: "subscription",
      status: status,
      customer: customer,
      cancel_at_period_end: cancel_at_period_end,
      metadata: { agent_id: agent.id.to_s },
      items: { object: "list", data: [ { price: { id: price }, current_period_end: period_end.to_i } ] }
    )
  end

  def v1 = self

  def subscriptions_service
    Service.new(retrieve: ->(id) { @subscriptions.fetch(id) { raise Stripe::InvalidRequestError.new("No such subscription", "id") } })
  end

  def customers
    Service.new(create: lambda { |params, opts|
      @created_customers << [ params, opts ]
      Stripe::StripeObject.construct_from(id: "cus_test_#{@created_customers.size}")
    })
  end

  def checkout
    sessions = Service.new(
      create: lambda { |params, opts|
        @checkout_sessions << [ params, opts ]
        id = "cs_test_#{@checkout_sessions.size}"
        @session_states[id] = { status: "open", subscription: nil }
        Stripe::StripeObject.construct_from(id: id, url: "https://checkout.stripe.com/c/pay/#{id}")
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

  module Helpers

    STARTER_PRICE = "price_test_starter".freeze
    STUDIO_PRICE = "price_test_studio".freeze

    STRIPE_ENV = {
      "STRIPE_SECRET_KEY" => "sk_test_fake", "STRIPE_WEBHOOK_SECRET" => "whsec_test_fake",
      "STRIPE_PRICE_STARTER" => STARTER_PRICE, "STRIPE_PRICE_STUDIO" => STUDIO_PRICE
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
