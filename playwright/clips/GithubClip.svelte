<script>
  // GitHub: repository-scoped access. Wren sees only the repos she's been given, pushes a branch, and opens a PR.
  import { GithubLogo, LockSimple, GitBranch, GitPullRequest, Check, Feather } from 'phosphor-svelte';
  import { ramp, ease, typed, loopFade, arrive } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 16;
  const repos = [
    ['sam/tides', true],
    ['sam/family-recipes', true],
    ['sam/work-payroll', false],
    ['sam/dotfiles', false],
  ];
</script>

<!-- bg-teal-100 -->
<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <div
      class="absolute rounded-2xl border bg-card p-7 shadow-md"
      style="left: 70px; top: 70px; width: 500px; {arrive(t, 0.3)}">
      <p class="flex items-center gap-3 text-[24px] font-semibold">
        <GithubLogo size={28} weight="fill" /> Wren's repositories
      </p>
      <div class="mt-6 space-y-3">
        {#each repos as [name, allowed], i}
          <div
            class="flex items-center justify-between rounded-lg border px-4 py-3 text-[20px]"
            style="{arrive(t, 0.8 + i * 0.3, 8)} {allowed ? '' : 'color: rgb(148 163 184)'}">
            <span class="font-mono text-[19px]">{name}</span>
            {#if allowed}<span class="flex items-center gap-1 text-[17px] text-teal-700"
                ><Check size={18} weight="bold" /> allowed</span>
            {:else}<span class="flex items-center gap-1 text-[17px]"><LockSimple size={17} /> not shared</span>{/if}
          </div>
        {/each}
      </div>
    </div>

    <div
      class="absolute rounded-xl bg-[#1d2127] px-6 py-5 font-mono text-[19px] leading-[1.6] text-slate-200 shadow-xl"
      style="left: 620px; top: 70px; width: 600px; {arrive(
        t,
        3.2
      )} font-family: 'Source Code Pro', ui-monospace, monospace">
      <p>
        <span class="text-teal-300">wren@house</span>:~/tides$ {typed('git switch -c lisbon-offsets', t, 3.5, 4.6)}
      </p>
      {#if t > 5.0}<p>
          <span class="text-teal-300">wren@house</span>:~/tides$ {typed(
            'git push -u origin lisbon-offsets',
            t,
            5.1,
            6.3
          )}
        </p>{/if}
      {#if t > 6.6}<p class="text-slate-400">* [new branch] lisbon-offsets</p>{/if}
    </div>

    <div
      class="absolute rounded-2xl border bg-card p-6 shadow-lg"
      style="left: 620px; top: 330px; width: 600px; {arrive(t, 7.6)}">
      <p class="flex items-center gap-2 text-[16px] font-medium text-emerald-700">
        <GitPullRequest size={20} weight="bold" /> Open · sam/tides #12
      </p>
      <p class="mt-2 text-[24px] font-semibold leading-snug">Fix Lisbon tide offsets for the harbour wall</p>
      <p class="mt-2 flex items-center gap-2 text-[17px] text-muted-foreground">
        <GitBranch size={17} /> lisbon-offsets → main · 1 commit
      </p>
      <p class="mt-4 rounded-lg bg-teal-100 px-4 py-3 text-[19px] leading-snug">
        <span class="mr-1 inline-flex items-center gap-1 font-medium text-teal-800"
          ><Feather size={16} weight="duotone" /> Wren</span>
        {typed(
          "Predictions now match the harbour board within two minutes. Have a look when you've had coffee.",
          t,
          8.4,
          11.4
        )}
      </p>
    </div>
  </div>
</div>
