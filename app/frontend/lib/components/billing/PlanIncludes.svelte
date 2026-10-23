<script>
  // What a plan includes, from the catalogue (Billing::Tier#features), as short
  // lines with icons. Shared by /pricing and the Billing tab so the two can't
  // describe a plan differently. The longer explanations live in the FAQ.
  import { Cpu, Sparkle, Waveform, CloudArrowUp, MagnifyingGlass, PlugsConnected } from 'phosphor-svelte';

  // omit: line keys to leave out, e.g. ['allowance'] where it is listed elsewhere.
  let { features, class: className = '', iconClass = 'text-muted-foreground', omit = [] } = $props();

  const lines = $derived([
    ...(features.connections?.length > 0
      ? [{ icon: PlugsConnected, text: 'Email, calendar, Telegram, WhatsApp, X, GitHub, DNS' }]
      : []),
    { icon: Cpu, text: `${features.vcpus} vCPU · ${features.ram_gb} GB RAM · ${features.disk_gb} GB disk` },
    { key: 'allowance', icon: Sparkle, text: `$${features.allowance_usd} a month of house model` },
    { icon: Waveform, text: `${features.transcription_hours} hours of transcription a month` },
    { icon: CloudArrowUp, text: `${features.backup_gb} GB of off-site backups` },
    ...(features.swarm_searches > 0
      ? [{ icon: MagnifyingGlass, text: `Swarm search, ${features.swarm_searches} a month` }]
      : []),
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
