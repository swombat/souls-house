<script>
  // What a plan includes, from the catalogue (Billing::Tier#features), as short
  // lines with icons. Shared by /pricing and the Billing tab so the two can't
  // describe a plan differently. Only what a plan delivers today: a line comes
  // back here when the catalogue starts sending it. The longer explanations
  // live in the FAQ.
  import { House, Sparkle, MagnifyingGlass, UsersThree } from 'phosphor-svelte';

  // omit: line keys to leave out, e.g. ['allowance'] where it is listed elsewhere.
  let { features, class: className = '', iconClass = 'text-muted-foreground', omit = [] } = $props();

  const lines = $derived([
    ...(features.hosting ? [{ key: 'hosting', icon: House, text: 'Hosting for one resident' }] : []),
    { key: 'allowance', icon: Sparkle, text: `$${features.allowance_usd} a month of house model` },
    ...(features.swarm_searches > 0
      ? [{ key: 'swarm', icon: MagnifyingGlass, text: `Swarm search, ${features.swarm_searches} a month` }]
      : []),
    ...(features.subagents ? [{ key: 'subagents', icon: UsersThree, text: 'Sub-agents' }] : []),
  ].filter((line) => !omit.includes(line.key)));
</script>

<ul class="space-y-3 {className}">
  {#each lines as line (line.text)}
    {@const Icon = line.icon}
    <li class="flex items-center gap-3">
      <Icon size={18} class="shrink-0 {iconClass}" />
      <span>{line.text}</span>
    </li>
  {/each}
</ul>
