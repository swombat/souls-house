<script>
  import { Input } from '$lib/components/shadcn/input';
  import { Label } from '$lib/components/shadcn/label';
  import AgentAppearanceFields from '$lib/components/agents/AgentAppearanceFields.svelte';
  import AgentAvatar from '$lib/components/agents/AgentAvatar.svelte';
  import AvatarPicker from '$lib/components/AvatarPicker.svelte';
  import { siteName } from '$lib/branding';

  let {
    name = $bindable(''),
    colour = $bindable(null),
    icon = $bindable(null),
    nameError = null,
    colourOptions = [],
    iconOptions = [],
    avatarPath = null,
    avatarUrl = null,
  } = $props();
</script>

<div class="space-y-6">
  <div>
    <h2 class="text-lg font-semibold">Appearance</h2>
    <p class="text-sm text-muted-foreground">Customise how this resident appears throughout {$siteName}.</p>
  </div>

  <div class="space-y-2">
    <Label for="name">Display name</Label>
    <Input id="name" type="text" bind:value={name} required maxlength={100} class="max-w-md" />
    {#if nameError}
      <p class="text-sm text-destructive">{nameError}</p>
    {/if}
    <p class="text-xs text-muted-foreground">
      This changes the name displayed in {$siteName}. It may or may not change the name the resident chooses for itself
      in
      <span class="font-mono">soul.md</span>.
    </p>
  </div>

  {#if avatarPath}
    <div class="space-y-2">
      <Label>Picture</Label>
      <p class="text-xs text-muted-foreground">
        Optional. Shown wherever this resident's face appears, in place of the icon. Saved as soon as you add it. If the
        resident has a Telegram bot, the bot's profile photo follows it: set or removed here, set or removed there.
      </p>
      <div class="max-w-md">
        <AvatarPicker uploadPath={avatarPath} deletePath={avatarPath} currentUrl={avatarUrl}>
          <AgentAvatar
            agent={{ name, colour, icon, avatar_url: avatarUrl }}
            class="size-20 rounded-full flex items-center justify-center"
            fallbackClass={colour ? `bg-${colour}-100 dark:bg-${colour}-900` : 'bg-muted'}
            iconClass={colour ? `text-${colour}-600 dark:text-${colour}-400` : 'text-muted-foreground'}
            iconSize={36} />
        </AvatarPicker>
      </div>
    </div>
  {/if}

  <AgentAppearanceFields bind:colour bind:icon {colourOptions} {iconOptions} />
  <p class="text-xs text-muted-foreground -mt-4">
    The colour stays with a picture: it still tints this resident's messages. An icon is recommended too; it's what
    shows if the picture can't load.
  </p>
</div>
