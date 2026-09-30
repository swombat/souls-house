# Svelte/Rails Synchronization

We need to synchronize the data between Svelte and Rails, so that when an object (e.g. the name of an account) is updated by one client, another client looking at the same page will automatically see the change within a short time period. And we want to do this with Svelte 5, Inertial-Rails, and Rails 8, with a minimum of boilerplate and also while minimising the amount of unnecessary traffic (e.g. we don't want to send a full page reload with a potentially large collection if only one property of the selected item has changed).

For this, we will use a very clever, minimal strategy that involves a javascript-side registry of interest, and a rails side cable channel broadcasts minimal markers of certain objects and collections being updated. The actual object update will happen via an inertia-rails partial reload of the relevant page.

## Rails side

We need to set up a channel with user authentication (visitors who are not logged in and authenticated do not get to subscribe to any specific objects or collections).

This channel should enable the browser to subscribe to updates for either:

1. A specific single object, by obfuscated ID. E.g. `Account:PNvAYr`
2. A collection within a specific object, e.g. `Account:PNvAYr/account_users`
3. A collection of all objects of a given type, e.g. `Account:all`; this third option will only be available to authenticated users who are site admins.

We will create a model concern that handles the broadcasting of updates to this cable channel. Unusually, the channel does not need to serialize the objects or collections, it just needs to broadcast a minimal marker of the object or collection being updated. So if Account PNvAYr is updated, the channel will broadcast `Account:PNvAYr` and `Account:all`.

This will then be used by the javascript side to do a partial reload of the relevant page and transparently update the relevant data.

On the Object side, the model concern will call `ActionCable.server.broadcast` upon update or creation or deletion, with the identifying string (`Account:PNvAYr`, `Account:PNvAYr/account_users`, `Account:all`) so that the object and collection will be broadcast to the cable channel, with code like this:

```ruby
  after_commit :broadcast_identifier

  private

  def broadcast_identifier
    ActionCable.server.broadcast("accounts", "Account:#{id}")
  end
```

## Javascript side

We need to set up a javascript side registry of interest. This will be a simple object that will be used to store the ids of the objects and collections that the user is interested in, along with the server-side properties they map to.

When the user navigates to a page, the page will subscribe to the relevant cable channel and specific objects and collections, and these will be unsubscribed from when the user navigates to a different page.

The registry will keep a mapping of "object id" vs "server-side property" for each object and collection that the page is interested in.

So for example, let's say a page is rendered from inertia with the following render method:

```ruby
  def index
    @accounts = Account.includes(:owner, account_users: :user)
                       .order(created_at: :desc)

    selected_account_id = params[:account_id]
    @selected_account = Account.find(selected_account_id) if selected_account_id

    render inertia: "admin/accounts", props: {
      accounts: @accounts.as_json(
        include: [ :owner ],
        methods: [ :users_count, :members_count, :active ]
        ),
      selected_account: @selected_account ? @selected_account.as_json(
        include: [ :owner, :account_users ],
        methods: [ :users_count, :members_count, :active ]
      ) : nil
    }
  end
```

The page may choose to subscribe to the following objects and collections:

1. `Account:all` => `accounts`
2. `Account:PNvAYr` => `selected_account`
3. `Account:PNvAYr/account_users` => `selected_account`

Then, if the page receives a notification that `Account:PNvAYr` has been updated, the page will [partially reload](https://inertia-rails.dev/guide/partial-reloads) the `selected_account` property with the new data:

```javascript
router.reload({ only: ['selected_account'] })
```

Since multiple notifications may be received in a short period, the reload will be debounced with a waiting time of 300ms, with properties grouped together in the same request if possible.

So if the page receives a notification that `Account:PNvAYr` has been updated, and `Account:all` has also been updated, the reload will be debounced with a waiting time of 300ms, and then request:

```javascript
router.reload({ only: ['selected_account', 'accounts'] })
```

If the user navigates to a different page, the page will unsubscribe from the relevant cable channel and unsubscribe from the relevant objects and collections.

## Svelte page setup

From a svelte page point of view, the boilerplate should be minimal:

```svelte
<script>
  import { onMount, onDestroy } from 'svelte';
  import { syncWithRails } from '$lib/sync-registry';

  let { accounts = [], selected_account = null } = $props();

  syncWithRails({ 'accounts': {
    'Account:all': 'accounts',
    'Account:' + selected_account.id: 'selected_account',
    'Account:' + selected_account.id + '/account_users': 'selected_account'
  }});

</script>
```

This should mean that the page will automatically update when the relevant data is updated, without a lot of boilerplate.