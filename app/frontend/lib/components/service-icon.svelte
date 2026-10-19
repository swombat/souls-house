<script>
  import {
    DropboxLogo,
    GoogleLogo,
    GithubLogo,
    Funnel,
    Bug,
    ShareNetwork,
    TelegramLogo,
    WhatsappLogo,
    GlobeHemisphereWest,
    Cloud,
    Heartbeat,
    XLogo,
    Receipt,
  } from 'phosphor-svelte';

  // The glyph for one service, in every place a service is shown. The tile
  // around it (colour, size) is the caller's; colours live in
  // service-presentation.js.
  let { provider, size = 24 } = $props();

  const icons = {
    dropbox: [DropboxLogo, 'fill'],
    google_workspace: [GoogleLogo, 'bold'],
    github: [GithubLogo, 'fill'],
    pipedrive: [Funnel, 'bold'],
    honeybadger: [Bug, 'bold'],
    tailscale: [ShareNetwork, 'bold'],
    telegram: [TelegramLogo, 'fill'],
    whatsapp: [WhatsappLogo, 'fill'],
    porkbun: [GlobeHemisphereWest, 'bold'],
    cloudflare: [Cloud, 'fill'],
    twitterapi_io: [XLogo, 'bold'],
    xero: [Receipt, 'bold'],
  };
  let [Icon, weight] = $derived(icons[provider] || [Heartbeat, 'fill']);
</script>

<Icon {size} {weight} />
