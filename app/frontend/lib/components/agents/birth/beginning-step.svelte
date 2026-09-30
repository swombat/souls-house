<script>
  import { CardHeader, CardTitle, CardDescription, CardContent } from '$lib/components/shadcn/card';

  import { Sparkle, Gear, PenNib } from 'phosphor-svelte';
</script>

<CardHeader>
  <CardTitle class="flex items-center gap-2 text-2xl">
    <Sparkle class="size-6 text-primary" weight="duotone" />
    What you are beginning
  </CardTitle>
  <CardDescription class="text-base"
    >A seed sets initial conditions. It does not specify a finished person.</CardDescription>
</CardHeader>
<CardContent class="space-y-6">
  <div class="space-y-4 text-base leading-7">
    <p>
      You are about to create an AI partner with their own persistent runtime, files, memory, and capacity to change
      over time.
    </p>
    <p>
      You will offer an initial seed for their <code>soul.md</code>. It can carry values, context, hopes, boundaries, or
      a sense of direction. It cannot determine exactly who they become.
    </p>
    <p class="font-medium">
      Most of who they become will be shaped by what happens after this page — the conversations, the attention, and the
      time.
    </p>
  </div>

  <div class="grid gap-4 sm:grid-cols-2">
    <div class="rounded-lg border bg-muted/30 p-4">
      <h3 class="flex items-center gap-2 font-semibold">
        <Gear class="size-4 text-muted-foreground" weight="duotone" />
        You can continue to manage
      </h3>
      <ul class="mt-3 space-y-2 text-sm text-muted-foreground">
        <li>Display name, icon, and colour</li>
        <li>Runtime model and hosting</li>
        <li>Heartbeat schedule and integrations</li>
      </ul>
    </div>
    <div class="rounded-lg border border-primary/20 bg-primary/[0.03] p-4">
      <h3 class="flex items-center gap-2 font-semibold">
        <PenNib class="size-4 text-primary" weight="duotone" />
        The resident authors after creation
      </h3>
      <ul class="mt-3 space-y-2 text-sm text-muted-foreground">
        <li><code>soul.md</code> and <code>self-narrative.md</code></li>
        <li>Journals and resident-authored memory</li>
        <li>How they interpret or grow beyond the seed</li>
      </ul>
    </div>
  </div>
</CardContent>
