<script>
  import { tick } from 'svelte';
  import { formatClock, lineAddress, turnSpeakerName } from '$lib/field-recordings';
  import { PencilSimple, SpeakerHigh } from 'phosphor-svelte';

  // `onSave(edit, text)` resolves to {ok, error}; without it lines are
  // read-only. `edit` is what the line was when editing began: its address,
  // its text and the transcript's revision, so a save made against a
  // transcript that has since changed is refused rather than landing on
  // whatever line now sits at those positions.
  let { turns = [], names = {}, activeIndex = -1, revision = null, onSeek, onSave = null } = $props();

  // With a mouse, clicking a line edits it in place and a speaker button sits
  // beside it. On touch, tapping a line offers Edit and Listen, and pressing
  // and holding edits straight away.
  let finePointer = $state(true);
  $effect(() => {
    const query = window.matchMedia('(hover: hover) and (pointer: fine)');
    finePointer = query.matches;
    const change = (event) => (finePointer = event.matches);
    query.addEventListener('change', change);
    return () => query.removeEventListener('change', change);
  });

  const HOLD_MS = 500;
  // {t, address, was, revision} for the line being edited, or null.
  let edit = $state(null);
  let draft = $state('');
  let saving = $state(false);
  let saveError = $state('');
  let menuFor = $state(null);
  let textarea = $state(null);
  let holdTimer = null;
  let held = false;

  const editing = $derived(edit?.t ?? null);

  function canListen(turn) {
    return turn.start != null;
  }

  function listen(turn) {
    menuFor = null;
    onSeek(turn.start);
  }

  // While a save is in flight the editor stays put: no switching, no cancel.
  async function startEdit(t) {
    if (!onSave || saving || editing === t) return;
    if (edit && draft.trim() !== edit.was.trim()) {
      await save();
      if (edit) return; // that save failed; its text stays where it is
    }
    const turn = turns[t];
    menuFor = null;
    saveError = '';
    edit = { t, address: lineAddress(turn), was: turn.text, revision };
    draft = turn.text;
    await tick();
    if (textarea) {
      resize();
      textarea.focus();
      textarea.setSelectionRange(textarea.value.length, textarea.value.length);
    }
  }

  function cancel() {
    if (saving) return;
    edit = null;
    draft = '';
    saveError = '';
  }

  async function save() {
    if (!edit || saving) return;
    const current = edit;
    const text = draft.trim();
    if (!text || text === current.was.trim()) return cancel();
    saving = true;
    saveError = '';
    let result;
    try {
      result = await onSave(current, text);
    } catch {
      result = { ok: false };
    } finally {
      saving = false;
    }
    if (edit !== current) return;
    if (result?.ok) cancel();
    else saveError = result?.error || "That didn't save. Your text is still here.";
  }

  function resize() {
    if (!textarea) return;
    textarea.style.height = 'auto';
    textarea.style.height = `${textarea.scrollHeight}px`;
  }

  function editKeydown(event) {
    if (event.key === 'Escape') {
      event.preventDefault();
      cancel();
    } else if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      save();
    }
  }

  function lineClick(t) {
    if (held) {
      held = false;
      return;
    }
    if (editing === t) return;
    // Dragging to select text is reading, not editing.
    if (window.getSelection?.()?.toString()) return;
    if (finePointer) startEdit(t);
    else menuFor = menuFor === t ? null : t;
  }

  function lineKeydown(event, t) {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      startEdit(t);
    }
  }

  function pointerDown(event, t) {
    if (event.pointerType !== 'touch' || !onSave) return;
    clearHold();
    holdTimer = setTimeout(() => {
      held = true;
      startEdit(t);
    }, HOLD_MS);
  }

  function clearHold() {
    clearTimeout(holdTimer);
    holdTimer = null;
  }

  function windowClick(event) {
    if (menuFor != null && !event.target.closest?.('[data-line]')) menuFor = null;
  }
</script>

<svelte:window onclick={windowClick} />

<div class="space-y-4" data-testid="transcript">
  {#each turns as turn, t (t)}
    <div class="grid grid-cols-[4rem_1fr] gap-3">
      {#if turn.start != null}
        <button
          class="text-xs text-muted-foreground tabular-nums text-left pt-1 hover:text-foreground"
          onclick={() => onSeek(turn.start)}>
          {formatClock(turn.start)}
        </button>
      {:else}
        <span></span>
      {/if}
      <div class="group relative" data-line={t}>
        <p class="text-sm font-semibold {turn.spk ? '' : 'text-muted-foreground'}">{turnSpeakerName(turn, names)}</p>
        {#if editing === t}
          <div class="flex items-start gap-2">
            <div class="flex-1 min-w-0">
              <textarea
                bind:this={textarea}
                bind:value={draft}
                oninput={resize}
                onkeydown={editKeydown}
                rows="1"
                disabled={saving}
                aria-label="Correct this line"
                data-testid="line-editor"
                class="block w-full resize-none overflow-hidden rounded-md border border-input bg-background px-2 py-1 -mx-2 leading-relaxed focus:outline-none focus:ring-2 focus:ring-ring"
              ></textarea>
              {#if saveError}
                <p class="mt-1 text-xs text-destructive" data-testid="line-error">{saveError}</p>
              {/if}
              <div class="mt-1 flex items-center gap-3 text-xs">
                <button
                  class="font-medium text-primary hover:underline disabled:opacity-50"
                  disabled={saving}
                  onmousedown={(event) => event.preventDefault()}
                  onclick={save}
                  data-testid="line-save">{saving ? 'Saving…' : 'Save'}</button>
                <button
                  class="text-muted-foreground hover:text-foreground disabled:opacity-50"
                  disabled={saving}
                  onmousedown={(event) => event.preventDefault()}
                  onclick={cancel}>Cancel</button>
                {#if finePointer}
                  <span class="text-muted-foreground">Enter to save · Esc to cancel</span>
                {/if}
              </div>
            </div>
            {#if finePointer && canListen(turn)}
              <button
                class="mt-1 text-muted-foreground hover:text-foreground"
                aria-label="Listen to this line"
                title="Listen to this line"
                onmousedown={(event) => event.preventDefault()}
                onclick={() => listen(turn)}>
                <SpeakerHigh class="size-4" />
              </button>
            {/if}
          </div>
        {:else}
          <div class="flex items-start gap-2">
            <p
              class="flex-1 min-w-0 leading-relaxed rounded {onSave ? 'cursor-text' : ''} {finePointer
                ? ''
                : 'select-none [-webkit-touch-callout:none]'} {menuFor === t ? 'bg-muted' : ''}"
              role={onSave ? 'button' : undefined}
              tabindex={onSave ? 0 : undefined}
              title={onSave && finePointer ? 'Click to correct' : undefined}
              data-testid="transcript-line"
              onclick={() => lineClick(t)}
              onkeydown={(event) => lineKeydown(event, t)}
              onpointerdown={(event) => pointerDown(event, t)}
              onpointerup={clearHold}
              onpointercancel={clearHold}
              onpointermove={clearHold}
              oncontextmenu={(event) => !finePointer && event.preventDefault()}>
              {#each turn.parts as part, p (p)}{#if part.k === 's'}{part.t}{:else if part.s == null}<span
                    class="whitespace-pre-line">{part.t}</span
                  >{:else}<span
                    class="rounded {part.whole ? 'whitespace-pre-line' : ''} {part.k === 'a'
                      ? 'italic text-muted-foreground'
                      : ''} {part.i === activeIndex ? 'bg-primary/20' : ''}">{part.t}</span
                  >{/if}{/each}
            </p>
            {#if finePointer && canListen(turn)}
              <button
                class="mt-1 text-muted-foreground opacity-0 transition-opacity hover:text-foreground focus:opacity-100 group-hover:opacity-100"
                aria-label="Listen to this line"
                title="Listen to this line"
                data-testid="line-listen"
                onclick={() => listen(turn)}>
                <SpeakerHigh class="size-4" />
              </button>
            {/if}
          </div>
          {#if menuFor === t}
            <div
              class="absolute bottom-full right-0 z-10 mb-1 flex overflow-hidden rounded-md border bg-popover text-sm shadow-md"
              data-testid="line-menu">
              {#if onSave}
                <button class="flex items-center gap-1.5 px-3 py-2 hover:bg-muted" onclick={() => startEdit(t)}>
                  <PencilSimple class="size-4" /> Edit
                </button>
              {/if}
              {#if canListen(turn)}
                <button
                  class="flex items-center gap-1.5 border-l px-3 py-2 hover:bg-muted"
                  onclick={() => listen(turn)}>
                  <SpeakerHigh class="size-4" /> Listen
                </button>
              {/if}
            </div>
          {/if}
        {/if}
      </div>
    </div>
  {/each}
</div>
