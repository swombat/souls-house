# stripe-ruby 20.x copies these public global settings into each new client.
# Checkout holds a billing lock over HTTP: avoid the SDK's 30/80s defaults and
# hidden retries. Uncertain mutations are recovered by their durable intents.
Stripe.open_timeout = 3
Stripe.read_timeout = 8
Stripe.write_timeout = 8
Stripe.max_network_retries = 0
