<script>
  import { useForm, Link } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { Switch } from '$lib/components/shadcn/switch';
  import { ArrowLeft } from 'phosphor-svelte';
  import RhythmResidentPicker from '$lib/components/rhythms/RhythmResidentPicker.svelte';
  import {
    CADENCES,
    MONTHS,
    MONTH_DAYS,
    WEEKDAYS,
    fieldErrors,
    formValues,
    formatWhen,
    needsShortMonthNote,
    previewQuery,
    rhythmPath,
    rhythmPreviewPath,
    rhythmsPath,
    submittableValues,
  } from '$lib/rhythms';

  let { account, rhythm = null, residents = [], timezones = [] } = $props();

  const editing = $derived(Boolean(rhythm?.id));
  const browserTimezone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';

  let form = useForm({ rhythm: formValues(rhythm ?? {}, browserTimezone) });

  const serverErrors = $derived({ ...(rhythm?.errors ?? {}), ...($form.errors ?? {}) });
  const errorsFor = (field) => fieldErrors(serverErrors, field);

  // Live preview: the server owns schedule maths, the form only asks.
  let preview = $state(null);
  let previewErrors = $state(null);
  let previewTimer;
  let previewSeq = 0;

  $effect(() => {
    const query = previewQuery($form.rhythm);
    clearTimeout(previewTimer);
    previewTimer = setTimeout(() => loadPreview(query), 250);
    return () => clearTimeout(previewTimer);
  });

  async function loadPreview(query) {
    const seq = ++previewSeq;
    try {
      const response = await fetch(`${rhythmPreviewPath(account.id)}?${query}`, {
        headers: { Accept: 'application/json' },
        credentials: 'same-origin',
      });
      const body = await response.json().catch(() => ({}));
      if (seq !== previewSeq) return;
      if (response.ok) {
        preview = body;
        previewErrors = null;
      } else {
        preview = null;
        previewErrors = body.errors ?? { base: ['Could not work out when this would happen.'] };
      }
    } catch {
      if (seq === previewSeq) {
        preview = null;
        previewErrors = { base: ['Preview unavailable right now.'] };
      }
    }
  }

  function submit(event) {
    event.preventDefault();
    $form.transform((data) => ({ rhythm: submittableValues(data.rhythm) }));
    if (editing) {
      $form.patch(rhythmPath(account.id, rhythm.id));
    } else {
      $form.post(rhythmsPath(account.id));
    }
  }

  const selectClass =
    'flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring';
  const backHref = $derived(editing ? rhythmPath(account.id, rhythm.id) : rhythmsPath(account.id));
</script>

<svelte:head>
  <title>{editing ? `Edit ${rhythm.title}` : 'New rhythm'}</title>
</svelte:head>

<div class="mx-auto max-w-3xl p-8">
  <Link href={backHref} class="mb-6 inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground">
    <ArrowLeft size={14} />
    {editing ? rhythm.title : 'Rhythms'}
  </Link>

  <h1 class="mb-1 text-3xl font-bold">{editing ? 'Edit rhythm' : 'New rhythm'}</h1>
  <p class="mb-8 text-muted-foreground">Each time it comes round, this opens a fresh conversation.</p>

  <form onsubmit={submit} class="space-y-8">
    <section class="space-y-2">
      <Label for="rhythm_title">Conversation title</Label>
      <Input id="rhythm_title" bind:value={$form.rhythm.title} placeholder="Weekly reflection" />
      <div class="flex items-center gap-3 pt-1">
        <Switch
          id="rhythm_append_date"
          checked={$form.rhythm.append_date}
          onCheckedChange={(checked) => ($form.rhythm.append_date = checked)} />
        <Label for="rhythm_append_date" class="font-normal">Append the date</Label>
      </div>
      {#if preview?.preview_title}
        <p class="text-xs text-muted-foreground">
          Next one will be called <span class="font-medium text-foreground">{preview.preview_title}</span>
        </p>
      {/if}
      {#each errorsFor('title') as error}<p class="text-sm text-destructive">{error}</p>{/each}
    </section>

    <section class="space-y-2">
      <Label for="rhythm_opening">Opening message</Label>
      <textarea
        id="rhythm_opening"
        bind:value={$form.rhythm.opening}
        rows="6"
        placeholder="Let's look back over this week's conversations. What did you notice, and how did it land with you?"
        class="flex w-full rounded-md border border-input bg-transparent px-3 py-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
      ></textarea>
      <p class="text-xs text-muted-foreground">
        Posted under your name, marked as scheduled. The residents are told it's a rhythm, not something you've just
        typed.
      </p>
      {#each errorsFor('opening') as error}<p class="text-sm text-destructive">{error}</p>{/each}
    </section>

    <section class="space-y-2">
      <Label>Residents</Label>
      <RhythmResidentPicker {residents} bind:selected={$form.rhythm.resident_ids} />
      {#each errorsFor('resident_ids') as error}<p class="text-sm text-destructive">{error}</p>{/each}
    </section>

    <section class="space-y-4">
      <Label>Repeat</Label>
      <div class="grid gap-4 sm:grid-cols-2">
        <div class="space-y-1">
          <Label for="rhythm_cadence" class="text-xs font-normal text-muted-foreground">How often</Label>
          <select id="rhythm_cadence" bind:value={$form.rhythm.cadence} class={selectClass}>
            {#each CADENCES as cadence}<option value={cadence.value}>{cadence.label}</option>{/each}
          </select>
        </div>

        {#if $form.rhythm.cadence === 'weekly'}
          <div class="space-y-1">
            <Label for="rhythm_weekday" class="text-xs font-normal text-muted-foreground">On</Label>
            <select id="rhythm_weekday" bind:value={$form.rhythm.weekday} class={selectClass}>
              {#each WEEKDAYS as day}<option value={day.value}>{day.label}</option>{/each}
            </select>
          </div>
        {/if}

        {#if $form.rhythm.cadence === 'yearly'}
          <div class="space-y-1">
            <Label for="rhythm_month" class="text-xs font-normal text-muted-foreground">Month</Label>
            <select id="rhythm_month" bind:value={$form.rhythm.month} class={selectClass}>
              {#each MONTHS as month}<option value={month.value}>{month.label}</option>{/each}
            </select>
          </div>
        {/if}

        {#if $form.rhythm.cadence === 'monthly' || $form.rhythm.cadence === 'yearly'}
          <div class="space-y-1">
            <Label for="rhythm_month_day" class="text-xs font-normal text-muted-foreground">Day</Label>
            <select id="rhythm_month_day" bind:value={$form.rhythm.month_day} class={selectClass}>
              {#each MONTH_DAYS as day}<option value={day}>{day}</option>{/each}
            </select>
          </div>
        {/if}

        <div class="space-y-1">
          <Label for="rhythm_time_of_day" class="text-xs font-normal text-muted-foreground">At</Label>
          <Input id="rhythm_time_of_day" type="time" bind:value={$form.rhythm.time_of_day} />
        </div>

        <div class="space-y-1">
          <Label for="rhythm_timezone" class="text-xs font-normal text-muted-foreground">Timezone</Label>
          <select id="rhythm_timezone" bind:value={$form.rhythm.timezone} class={selectClass}>
            {#each timezones as zone}<option value={zone.value}>{zone.label}</option>{/each}
          </select>
        </div>
      </div>

      {#if needsShortMonthNote($form.rhythm)}
        <p class="text-xs text-muted-foreground">
          {$form.rhythm.cadence === 'yearly'
            ? 'In years without a 29 February, it happens on the 28th.'
            : 'In shorter months, it happens on the last day of the month.'}
        </p>
      {/if}
      {#each ['cadence', 'weekday', 'month_day', 'month', 'time_of_day', 'timezone'] as field}
        {#each errorsFor(field) as error}<p class="text-sm text-destructive">{error}</p>{/each}
      {/each}

      <div class="rounded-md border border-border bg-muted/30 px-4 py-3 text-sm" aria-live="polite">
        {#if preview}
          <span class="text-muted-foreground">{preview.schedule_description}.</span>
          First one:
          <span class="font-medium">{formatWhen(preview.next_run_at, $form.rhythm.timezone)}</span>
        {:else if previewErrors}
          <span class="text-muted-foreground">Fill in the details above to see when it will first happen.</span>
        {:else}
          <span class="text-muted-foreground">Working out when it happens…</span>
        {/if}
      </div>
    </section>

    {#each errorsFor('base') as error}<p class="text-sm text-destructive">{error}</p>{/each}

    <div class="flex items-center gap-3">
      <Button type="submit" disabled={$form.processing}>{editing ? 'Save changes' : 'Create rhythm'}</Button>
      <Link href={backHref} class="text-sm text-muted-foreground hover:text-foreground">Cancel</Link>
    </div>
  </form>
</div>
