# Reading a Stripe subscription's items: all of them, past the embedded first
# page, since a missing line would be read as a change to the bill.
module Billing
  module Items

    module_function

    def all(remote, client:)
      items = remote.items.data.to_a
      return items unless remote.items.respond_to?(:has_more) && remote.items.has_more

      cursor = items.last&.id
      loop do
        page = client.v1.subscription_items.list({ subscription: remote.id, limit: 100, starting_after: cursor })
        items.concat(page.data.to_a)
        break unless page.has_more

        following = page.data.last&.id
        raise NotReady, "Stripe's item listing for #{remote.id} is incomplete" if following.blank? || following == cursor

        cursor = following
      end
      raise NotReady, "Stripe's item listing for #{remote.id} repeats an item" unless items.map(&:id).uniq.size == items.size

      items
    end

    def id(value) = value.respond_to?(:id) ? value.id : value

  end
end
