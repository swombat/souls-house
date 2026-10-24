<script>
  import { onDestroy, untrack } from 'svelte';
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';

  // The parent keys this form by account and source. The captured identity
  // also guards detached handlers and late responses from the previous form.
  let { accountId, stream } = $props();
  const identity = untrack(() => ({ accountId, sourceId: stream.source?.id ?? null }));
  const base = `/accounts/${identity.accountId}/field/tweet_stream`;
  let active = true;
  onDestroy(() => (active = false));

  function settings(source) {
    return {
      include_replies: source?.include_replies ?? true,
      include_quotes: source?.include_quotes ?? true,
      include_reposts: source?.include_reposts ?? false,
      own_monthly_usd_limit: String(source?.own_monthly_usd_limit ?? '5'),
    };
  }

  function normalizedLimit(value) {
    // A trailing decimal point/empty input is an editing string, not a
    // pristine numeric value. Text input keeps it intact across refreshes.
    return /^\d+(?:\.\d+)?$/.test(value) ? Number(value) : `draft:${value}`;
  }

  function equal(left, right) {
    return (
      left.include_replies === right.include_replies &&
      left.include_quotes === right.include_quotes &&
      left.include_reposts === right.include_reposts &&
      normalizedLimit(left.own_monthly_usd_limit) === normalizedLimit(right.own_monthly_usd_limit)
    );
  }

  let baseline = $state(untrack(() => settings(stream.source)));
  let draft = $state(untrack(() => ({ ...baseline })));
  let handle = $state('');
  let saving = $state(false);
  let error = $state('');
  const remoteChanged = $derived(!!stream.source && !equal(settings(stream.source), baseline));

  $effect(() => {
    const incoming = settings(stream.source);
    // A status-only refresh never rewrites the local input strings. Once
    // dirty, keep the captured baseline until an acknowledged save or revert.
    if (stream.source && !saving && !error && equal(draft, baseline) && !equal(incoming, baseline)) {
      draft = incoming;
      baseline = incoming;
    }
  });

  function currentIdentity() {
    return active && accountId === identity.accountId && (stream.source?.id ?? null) === identity.sourceId;
  }

  function submit(event) {
    event.preventDefault();
    if (saving || !currentIdentity() || (!identity.sourceId && !stream.funding)) return;
    const value = handle.trim().replace(/^@/, '');
    if (!identity.sourceId && !value) return;
    const submitted = { ...draft };
    saving = true;
    error = '';
    const options = {
      preserveScroll: true,
      onSuccess: (page) => {
        if (!currentIdentity()) return;
        const returned = page.props.tweet_stream?.source;
        const sameAccount = page.props.account?.id === identity.accountId;
        const sameSource = identity.sourceId ? returned?.id === identity.sourceId : returned?.handle === value;
        // Controller validation failures redirect with an alert, which Inertia
        // calls a successful visit. Only the returned values acknowledge a save.
        if (!sameAccount || !sameSource || !equal(settings(returned), submitted)) {
          error = 'The save was not confirmed. Your draft is still here; please try again.';
          return;
        }
        baseline = settings(returned);
        // Never assign the draft here: the user may have edited it in flight.
      },
      onError: () => {
        if (currentIdentity()) error = 'Could not save. Your draft is still here; please try again.';
      },
      onFinish: () => {
        if (currentIdentity()) saving = false;
      },
    };
    const data = { field_tweet_source: identity.sourceId ? submitted : { handle: value, ...submitted } };
    if (identity.sourceId) router.patch(base, data, options);
    else router.post(base, data, options);
  }
</script>

<form
  onsubmit={submit}
  hidden={!stream.source && !stream.funding}
  class="space-y-3 {stream.source ? 'border-t pt-3' : ''}"
  data-testid={stream.source ? 'tweet-stream-settings-form' : 'tweet-stream-follow-form'}>
  {#if !stream.source}
    <div class="space-y-1">
      <Label for="tweet-stream-handle">Follow an X handle</Label>
      <Input id="tweet-stream-handle" bind:value={handle} placeholder="jack" maxlength={16} required />
    </div>
  {/if}
  <div class="space-y-1.5">
    <label class="flex items-center gap-2 text-sm">
      <input type="checkbox" bind:checked={draft.include_replies} /> Include its replies
    </label>
    <label class="flex items-center gap-2 text-sm">
      <input type="checkbox" bind:checked={draft.include_quotes} /> Include its quote-posts
    </label>
    <label class="flex items-center gap-2 text-sm">
      <input type="checkbox" bind:checked={draft.include_reposts} /> Include its reposts
    </label>
  </div>
  {#if (stream.source?.funding ?? stream.funding) === 'own'}
    <div class="space-y-1">
      <Label for="tweet-stream-limit">Monthly limit on your TwitterAPI.io spend (USD)</Label>
      <Input
        id="tweet-stream-limit"
        inputmode="decimal"
        pattern={'(100([.]0{1,2})?|[0-9]{1,2}([.][0-9]{1,2})?)'}
        title="An amount from 0 to 100 USD, with up to two decimal places"
        required
        class="w-28"
        bind:value={draft.own_monthly_usd_limit} />
    </div>
  {/if}
  {#if !stream.source}
    <p class="text-sm text-muted-foreground">
      Posts from now on are brought in, not its history. Checked every {stream.poll_minutes} minutes, up to {stream.daily_import_cap}
      new tweets a day.
      {#if stream.funding === 'own'}
        Paid by this account's TwitterAPI.io integration, up to the monthly limit above.
      {:else if stream.house_available}
        Paid by the house, up to ${stream.account_monthly_usd_ceiling} a month.
      {:else}
        Collection paid by the house is paused right now, so nothing will be collected until it resumes.
      {/if}
      Search may miss or delay some posts; this is not a complete archive.
    </p>
  {:else if remoteChanged}
    <p class="text-sm text-muted-foreground">Settings changed elsewhere. Your unsaved draft has been kept.</p>
  {/if}
  {#if error}<p role="alert" class="text-sm text-destructive">{error}</p>{/if}
  <Button
    type="submit"
    size="sm"
    variant={stream.source ? 'outline' : 'default'}
    disabled={saving || (!stream.source && !handle.trim())}>
    {stream.source ? 'Save settings' : 'Follow'}
  </Button>
</form>
