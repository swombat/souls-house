# Installing Pay

Pay's installation is pretty straightforward. We'll add the gems, add some migrations, and update our models.

## Gemfile

Add these lines to your application's Gemfile:

```ruby
gem "pay", "~> 11.1"

# To use Stripe, also include:
gem "stripe", "~> 15.3"

# To use Braintree + PayPal, also include:
gem "braintree", "~> 4.29"

# To use Paddle Billing or Paddle Classic, also include:
gem "paddle", "~> 2.7.1"

# To use Lemon Squeezy, also include:
gem "lemonsqueezy", "~> 1.1"

# To use Receipts gem for creating invoice and receipt PDFs, also include:
gem "receipts", "~> 2.4"
```

And then execute:

```shell
bundle
```

## Migrations

Copy the Pay migrations to your app:

```shell
bin/rails pay:install:migrations
```

Then run the migrations:

```shell
bin/rails db:migrate
```

Make sure you've configured your ActionMailer `default_url_options` so Pay can generate links (for features like Stripe Checkout).

```ruby
# config/application.rb
config.action_mailer.default_url_options = { host: "example.com" }
```

## Models

To add Pay to a model in your Rails app, simply add `pay_customer` to the model:

```ruby
# == Schema Information
#
# Table name: users
#
# id :bigint not null, primary key
# email :string default(""), not null

class User < ApplicationRecord
 pay_customer
end
```

**Note:** Pay requires your model to have an `email` attribute. Email is a field that is required by Stripe, Braintree, etc to create a Customer record.

For pay to also send the customer's name to your payment processor, your model should respond to one of the following methods:
- `name`
- `first_name` and `last_name`
