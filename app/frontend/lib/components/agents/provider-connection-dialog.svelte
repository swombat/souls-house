<script>
  import { Button } from '$lib/components/shadcn/button';
  import * as Dialog from '$lib/components/shadcn/dialog';
  import { Copy } from 'phosphor-svelte';
  let { subscription } = $props();
  let agent = $derived(subscription.agent);
  let connectOpen = $derived(subscription.connectOpen);
  let ceremony = $derived(subscription.ceremony);
  let actionError = $derived(subscription.actionError);
  let startingConnection = $derived(subscription.startingConnection);
  let secondsRemaining = $derived(subscription.secondsRemaining);
  let browserCode = $derived(subscription.browserCode);
  let submittingCode = $derived(subscription.submittingCode);
  let isAnthropic = $derived(subscription.isAnthropic);
  let isGemini = $derived(subscription.isGemini);
  const beginConnection = (...args) => subscription.beginConnection(...args);
  const cancelConnection = (...args) => subscription.cancelConnection(...args);
  const copyCode = (...args) => subscription.copyCode(...args);
  const submitBrowserCode = (...args) => subscription.submitBrowserCode(...args);
</script>

<Dialog.Root
  open={connectOpen}
  onOpenChange={(open) => {
    if (!open && connectOpen) cancelConnection();
  }}>
  <Dialog.Content
    onInteractOutside={(event) => {
      event.preventDefault();
      cancelConnection();
    }}>
    <Dialog.Header>
      <Dialog.Title>
        {isAnthropic
          ? 'Connect Claude Code clamping'
          : isGemini
            ? 'Connect Google Antigravity clamping'
            : `Connect ${agent.provider_name} subscription`}
      </Dialog.Title>
      <Dialog.Description>
        {#if isAnthropic}
          Sign Claude Code into the subscription this resident should be clamped to. The connection belongs only to
          {agent.name} and is stored in its private runtime state volume.
        {:else if isGemini}
          Sign the official Antigravity CLI into the Google AI subscription this resident should use. This experimental
          integration is not supported by Google and may put related Gemini developer services at risk. The connection
          belongs only to {agent.name} and is stored in its private runtime state volume.
        {:else}
          This connection belongs only to {agent.name} and is stored in its private runtime state volume.
        {/if}
      </Dialog.Description>
    </Dialog.Header>

    <div class="space-y-4 py-2">
      {#if startingConnection}
        <p class="text-sm text-muted-foreground">Starting provider sign-in…</p>
      {:else if actionError}
        <div class="rounded-md border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
          {actionError}
        </div>
      {:else if ceremony?.status === 'awaiting_code'}
        <div class="space-y-3">
          <a
            class="font-medium text-primary underline underline-offset-4"
            href={ceremony.verification_url}
            target="_blank"
            rel="noreferrer">
            {isGemini ? 'Open Google sign-in' : 'Open Claude sign-in'}
          </a>
          <p class="text-sm text-muted-foreground">
            {isGemini
              ? 'Complete sign-in in the browser, then paste the authorization code shown by Antigravity below.'
              : 'Complete sign-in in the browser. If the final localhost page does not load, copy its full URL from the address bar and paste it below.'}
          </p>
          <input
            class="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            type="text"
            autocomplete="one-time-code"
            bind:value={subscription.browserCode}
            placeholder={isGemini
              ? 'Paste the Antigravity authorization code'
              : 'Paste the localhost callback URL or code'} />
          <Button type="button" disabled={!browserCode.trim() || submittingCode} onclick={submitBrowserCode}>
            {submittingCode ? 'Submitting…' : 'Submit code'}
          </Button>
          <p class="text-sm text-muted-foreground">
            {secondsRemaining > 0
              ? `Sign-in expires in ${Math.floor(secondsRemaining / 60)}:${String(secondsRemaining % 60).padStart(2, '0')}.`
              : 'Sign-in expired.'}
          </p>
        </div>
      {:else if ceremony?.status === 'pending'}
        <div class="space-y-3">
          <a
            class="font-medium text-primary underline underline-offset-4"
            href={ceremony.verification_url}
            target="_blank"
            rel="noreferrer">
            Open provider sign-in
          </a>
          <div class="flex items-center gap-2">
            <code class="rounded-md bg-muted px-4 py-2 text-xl font-semibold tracking-widest"
              >{ceremony.user_code}</code>
            <Button type="button" variant="outline" size="icon" aria-label="Copy one-time code" onclick={copyCode}>
              <Copy size={18} />
            </Button>
          </div>
          <p class="text-sm text-muted-foreground">
            {secondsRemaining > 0
              ? `Code expires in ${Math.floor(secondsRemaining / 60)}:${String(secondsRemaining % 60).padStart(2, '0')}.`
              : 'Code expired.'}
          </p>
          <div class="rounded-md border border-amber-400/40 bg-amber-50 p-3 text-sm text-amber-950">
            Device codes are a common phishing target. Never share this code.
          </div>
          <p class="text-sm text-muted-foreground">Waiting for sign-in to finish…</p>
        </div>
      {:else if ceremony?.status === 'finalizing' || ceremony?.status === 'starting'}
        <p class="text-sm text-muted-foreground">Finishing provider sign-in…</p>
      {:else if ceremony?.status === 'connected'}
        <div class="rounded-md border border-emerald-500/30 bg-emerald-500/10 p-4 text-sm">
          {#if isAnthropic}
            Connected successfully{ceremony.email ? ` as ${ceremony.email}` : ''}. Claude Code clamping is now selected,
            and resident usage draws on this Claude plan.
          {:else if isGemini}
            Connected successfully. Antigravity clamping is now selected, and resident usage draws on this Google AI
            plan.
          {:else}
            Connected successfully{ceremony.email ? ` as ${ceremony.email}` : ''}. Resident usage now draws on this
            account's personal plan quota.
          {/if}
        </div>
      {:else if ceremony?.status === 'expired' || ceremony?.status === 'failed'}
        <div class="space-y-3">
          <p class="text-sm text-destructive">{ceremony.message || 'The provider connection was not completed.'}</p>
          <Button type="button" onclick={beginConnection}>Get a new code</Button>
        </div>
      {/if}
    </div>

    <Dialog.Footer>
      <Button type="button" variant="outline" onclick={cancelConnection}>
        {ceremony?.status === 'connected' ? 'Done' : 'Cancel'}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
