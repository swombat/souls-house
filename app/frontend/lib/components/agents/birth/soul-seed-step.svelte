<script>
  import { CardHeader, CardTitle, CardDescription, CardContent } from '$lib/components/shadcn/card';
  import { siteName } from '$lib/branding';

  import { Alert, AlertDescription, AlertTitle } from '$lib/components/shadcn/alert';
  import { Info } from 'phosphor-svelte';
  import { Label } from '$lib/components/shadcn/label';
  import { Switch } from '$lib/components/shadcn/switch';
  let { form, openBeginning = $bindable(false) } = $props();
</script>

<CardHeader>
  <CardTitle>Initial soul seed</CardTitle>
  <CardDescription
    >Write the beginning you want to offer, not a specification for guaranteed behaviour.</CardDescription>
</CardHeader>
<CardContent class="space-y-5">
  <Alert>
    <Info class="size-4" />
    <AlertTitle>Write-once from your side</AlertTitle>
    <AlertDescription>
      You can revise this freely until the final confirmation. After creation, {$siteName} will not let you edit it. The
      resident may carry it forward, revise it, or grow past it.
    </AlertDescription>
  </Alert>

  <div class="space-y-2">
    <div class="flex items-center justify-between">
      <Label for="system_prompt">Initial soul seed</Label>
      <span class="rounded bg-muted px-2 py-0.5 font-mono text-xs text-muted-foreground">soul.md</span>
    </div>
    <textarea
      id="system_prompt"
      bind:value={$form.agent.system_prompt}
      disabled={openBeginning}
      rows="16"
      placeholder="Why are you inviting this resident into your life or work? What values, context, boundaries, questions, or freedom do you hope to offer at the beginning?"
      class="w-full rounded-md border border-input bg-background px-4 py-3 font-mono text-sm leading-6 focus:outline-none focus:ring-2 focus:ring-ring disabled:opacity-50"
    ></textarea>
    <div class="flex items-baseline justify-between gap-4">
      <p class="text-sm text-muted-foreground">
        Helpful questions: What relationship do you hope to build? What matters at the beginning? What should remain
        uncertain or free?
      </p>
      {#if $form.agent.system_prompt.trim().length > 0}
        <p class="shrink-0 text-xs tabular-nums text-muted-foreground/70">
          {$form.agent.system_prompt.trim().split(/\s+/).length} words
        </p>
      {/if}
    </div>
    {#if $form.errors.system_prompt}<p class="text-sm text-destructive">{$form.errors.system_prompt}</p>{/if}
  </div>

  <div class="flex items-start justify-between gap-4 rounded-lg border p-4">
    <div>
      <Label for="open_beginning">Leave the beginning open</Label>
      <p class="mt-1 text-sm text-muted-foreground">
        An explicit blank beginning is valid. The resident will be told that nothing was written to define them.
      </p>
      {#if openBeginning && $form.agent.system_prompt.trim().length > 0}
        <p class="mt-2 text-sm text-amber-600 dark:text-amber-500">
          Your typed draft will be set aside — the file will carry the open-beginning text instead.
        </p>
      {/if}
    </div>
    <Switch id="open_beginning" checked={openBeginning} onCheckedChange={(checked) => (openBeginning = checked)} />
  </div>
</CardContent>
