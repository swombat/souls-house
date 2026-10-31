export function serviceDescription(service) {
  if (service.key === 'dropbox') return 'Files and folders, with provider-enforced scope choices.';
  if (service.key === 'google_workspace')
    return 'Gmail, Calendar, Drive, Docs, Sheets, Slides, and Meet through the Google Workspace gws client.';
  if (service.key === 'xero')
    return 'Contacts, invoices, bank transactions and reports in the Xero organisations you choose.';
  if (service.key === 'freeagent')
    return 'Invoices, bank explanations, VAT and receipts, within the approving FreeAgent user’s permissions.';
  if (service.key === 'oura') return 'Sleep, readiness, activity, and direct Oura API access.';
  if (service.key === 'github') return 'Repository-scoped access using a fine-grained personal access token.';
  if (service.key === 'pipedrive')
    return 'Create and update CRM leads, people and deals as you, with your personal API token.';
  if (service.key === 'honeybadger')
    return 'Read production errors, their backtraces and request context, with your personal auth token.';
  if (service.key === 'tailscale') return 'SSH to your own machines over a private tailnet, one node per resident.';
  if (service.key === 'telegram') return 'Your own Telegram account: residents can read and search the chats it syncs.';
  if (service.key === 'whatsapp')
    return 'Your own WhatsApp, linked as a device: residents can read the chats it receives. Nothing is sent.';
  if (service.key === 'porkbun') return 'DNS records, URL forwards and nameservers for your Porkbun domains.';
  if (service.key === 'cloudflare')
    return 'DNS records and redirects for your Cloudflare zones, with a scoped API token.';
  if (service.key === 'ghost') return 'Write articles on your Ghost blog: drafts by default, published when you ask.';
  if (service.key === 'twitterapi_io')
    return "Pays for this account's tweet streams in the Field, from your own TwitterAPI.io credit.";
  return 'Direct external-service access for selected residents.';
}

export function serviceIconClass(serviceKey) {
  if (serviceKey === 'dropbox') return 'bg-blue-600 text-white';
  if (serviceKey === 'google_workspace') return 'bg-green-600 text-white';
  if (serviceKey === 'xero') return 'bg-cyan-600 text-white';
  if (serviceKey === 'freeagent') return 'bg-blue-700 text-white';
  if (serviceKey === 'github') return 'bg-neutral-900 text-white';
  if (serviceKey === 'pipedrive') return 'bg-emerald-700 text-white';
  if (serviceKey === 'honeybadger') return 'bg-amber-600 text-white';
  if (serviceKey === 'tailscale') return 'bg-slate-700 text-white';
  if (serviceKey === 'telegram') return 'bg-sky-500 text-white';
  if (serviceKey === 'whatsapp') return 'bg-green-500 text-white';
  if (serviceKey === 'porkbun') return 'bg-pink-600 text-white';
  if (serviceKey === 'cloudflare') return 'bg-orange-500 text-white';
  if (serviceKey === 'ghost') return 'bg-zinc-800 text-white';
  if (serviceKey === 'twitterapi_io') return 'bg-neutral-800 text-white';
  return 'bg-red-500 text-white';
}
