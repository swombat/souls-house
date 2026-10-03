<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Badge } from '$lib/components/shadcn/badge';
  import * as Card from '$lib/components/shadcn/card';
  import { User, Users } from 'phosphor-svelte';

  let { account, canBePersonal = false, membersCount = 1, onConvert } = $props();

  const kinds = [
    {
      id: 'personal',
      label: 'Personal',
      icon: User,
      points: [
        'One person: you are its only member and its owner.',
        'Nobody can be invited.',
        'Its name follows your own name unless you rename it.',
      ],
    },
    {
      id: 'team',
      label: 'Team',
      icon: Users,
      points: [
        'Several people share its residents, keys and settings.',
        'Members can be invited and removed.',
        'Every confirmed member can change most settings; only owners and admins can change model API keys.',
      ],
    },
  ];

  const current = $derived(account.personal ? 'personal' : 'team');
</script>

<Card.Root>
  <Card.Header>
    <div class="flex items-center justify-between gap-4">
      <div>
        <Card.Title>Account type</Card.Title>
        <Card.Description>Whether this account belongs to one person or is shared.</Card.Description>
      </div>
      <Badge variant={account.personal ? 'default' : 'secondary'}>{account.personal ? 'Personal' : 'Team'}</Badge>
    </div>
  </Card.Header>
  <Card.Content class="space-y-4">
    <div class="grid gap-3 md:grid-cols-2">
      {#each kinds as kind (kind.id)}
        <div
          class="rounded-lg border p-4 text-sm {current === kind.id
            ? 'border-primary bg-primary/5'
            : 'text-muted-foreground'}">
          <div class="mb-2 flex items-center gap-2 font-medium text-foreground">
            <kind.icon size={18} />
            {kind.label}
            {#if current === kind.id}<span class="text-xs font-normal text-muted-foreground">(this account)</span>{/if}
          </div>
          <ul class="list-disc space-y-1 pl-5">
            {#each kind.points as point}
              <li>{point}</li>
            {/each}
          </ul>
        </div>
      {/each}
    </div>

    <p class="text-sm text-muted-foreground">
      Converting changes who can belong to the account. Residents, conversations and keys stay where they are.
      {#if account.personal}
        You choose the team name when you convert.
      {:else}
        Converting to personal renames the account after you.
      {/if}
    </p>

    {#if account.personal}
      <Button onclick={onConvert} variant="outline">Convert to team account</Button>
    {:else if canBePersonal}
      <Button onclick={onConvert} variant="outline">Convert to personal account</Button>
    {:else}
      <p class="text-sm text-muted-foreground">
        A team account can only become personal when it has one member. This one has {membersCount}.
      </p>
    {/if}
  </Card.Content>
</Card.Root>
