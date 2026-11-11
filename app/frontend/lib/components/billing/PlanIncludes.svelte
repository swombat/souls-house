<script>
  // What an account plan includes, from the catalogue (Billing::AccountPlan
  // #features), as short lines with icons. Shared by /pricing and the Billing
  // tab so the two can't describe a plan differently. Only what a plan
  // delivers today; the longer explanations live in the FAQ.
  import { House, MagnifyingGlass, User, UsersThree, CheckCircle } from 'phosphor-svelte';
  import { accountPlanLines } from '$lib/pricing';

  // plan: one entry of the account_plans prop. withResident: the public cards
  // count the small resident every plan comes with; the Billing tab lists
  // residents on their own.
  let { plan, withResident = true, class: className = '', iconClass = 'text-muted-foreground' } = $props();

  const ICONS = { members: User, everything: CheckCircle, subagents: UsersThree, swarm: MagnifyingGlass };

  const lines = $derived([
    ...accountPlanLines(plan).map((line) => ({
      ...line,
      icon: line.key === 'members' && plan?.features?.members === 'several' ? UsersThree : ICONS[line.key],
    })),
    ...(withResident ? [{ key: 'resident', icon: House, text: 'One small resident included' }] : []),
  ]);
</script>

<ul class="space-y-3 {className}">
  {#each lines as line (line.key)}
    {@const Icon = line.icon}
    <li class="flex items-center gap-3">
      <Icon size={18} class="shrink-0 {iconClass}" />
      <span>{line.text}</span>
    </li>
  {/each}
</ul>
