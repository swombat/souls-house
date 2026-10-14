<script>
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Switch } from '$lib/components/shadcn/switch';

  let { form, status = {} } = $props();
</script>

<Card>
  <CardHeader>
    <CardTitle>Tweet streams</CardTitle>
    <CardDescription>
      When this is on, an account manager can have one public X handle followed into the account's Field: its own posts,
      and by default its own replies and quote-posts. Collection uses TwitterAPI.io's search (read-only, no X login)
      every few minutes, from the moment the handle is added. TwitterAPI.io charges $0.15 per 1,000 tweets returned, at
      least $0.00015 a call, so an idle handle polled every 15 minutes costs about $0.43 a month. Each account pays with
      its own TwitterAPI.io integration (Settings → Integrations). The house key pays only for accounts granted it under
      Site Admin → Accounts, within the ceilings below. An account with its own integration is never paid for by the
      house, even when its key is refused.
    </CardDescription>
  </CardHeader>
  <CardContent class="space-y-4">
    <label class="flex items-center gap-3">
      <Switch
        aria-label="Allow tweet streams"
        checked={!!form.field_tweets_enabled}
        onCheckedChange={(on) => (form.field_tweets_enabled = on)} />
      <span class="font-medium">Allow tweet streams</span>
    </label>

    <div class="grid gap-4 sm:grid-cols-2">
      <div class="space-y-2">
        <label for="field_tweets_site_monthly_usd_ceiling" class="font-medium"
          >House spend, all accounts, per month (USD)</label>
        <input
          id="field_tweets_site_monthly_usd_ceiling"
          class="block h-10 w-28 rounded-md border bg-background px-3"
          type="number"
          min="0"
          max="1000"
          step="0.01"
          required
          bind:value={form.field_tweets_site_monthly_usd_ceiling} />
        <p class="text-sm text-muted-foreground">At 0, only accounts with their own integration are collected.</p>
      </div>
      <div class="space-y-2">
        <label for="field_tweets_account_monthly_usd_ceiling" class="font-medium"
          >House spend per account per month (USD)</label>
        <input
          id="field_tweets_account_monthly_usd_ceiling"
          class="block h-10 w-28 rounded-md border bg-background px-3"
          type="number"
          min="0"
          max="100"
          step="0.01"
          required
          bind:value={form.field_tweets_account_monthly_usd_ceiling} />
      </div>
      <div class="space-y-2">
        <label for="field_tweets_daily_import_cap" class="font-medium">New tweets per account per day</label>
        <input
          id="field_tweets_daily_import_cap"
          class="block h-10 w-28 rounded-md border bg-background px-3"
          type="number"
          min="0"
          max="1000"
          step="1"
          required
          bind:value={form.field_tweets_daily_import_cap} />
        <p class="text-sm text-muted-foreground">Over it, tweets wait in a backlog for the next day.</p>
      </div>
      <div class="space-y-2">
        <label for="field_tweets_poll_minutes" class="font-medium">Minutes between checks</label>
        <input
          id="field_tweets_poll_minutes"
          class="block h-10 w-28 rounded-md border bg-background px-3"
          type="number"
          min="5"
          max="1440"
          step="1"
          required
          bind:value={form.field_tweets_poll_minutes} />
      </div>
    </div>

    <p class="text-sm text-muted-foreground" data-testid="field-tweets-status">
      House key: {status.house_key_configured ? 'configured' : 'not configured'}, granted to {status.house_key_accounts ??
        0} account(s). This month the house has spent ${Number(status.house_spent_this_month ?? 0).toFixed(4)} on {status.house_calls_this_month ??
        0} calls, which returned
      {status.returned_this_month ?? 0} tweets ({status.already_stored_this_month ?? 0} of them already stored).
    </p>

    {#if status.house_halted_at}
      <div class="rounded-md border border-destructive/40 p-3 text-sm" data-testid="field-tweets-halted">
        <p>
          Collection paid by the house stopped on {new Date(status.house_halted_at).toLocaleString()}: {status.house_halt_reason}
        </p>
        <label class="mt-2 flex items-center gap-2">
          <input type="checkbox" bind:checked={form.field_tweets_resume_house} />
          <span>The key is fixed: resume when saved</span>
        </label>
      </div>
    {/if}
  </CardContent>
</Card>
