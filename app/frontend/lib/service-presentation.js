export function serviceDescription(service) {
  if (service.key === 'dropbox') return 'Files and folders, with provider-enforced scope choices.';
  if (service.key === 'google_workspace')
    return 'Gmail, Calendar, Drive, Docs, Sheets, Slides, and Meet through the Google Workspace gws client.';
  if (service.key === 'oura') return 'Sleep, readiness, activity, and direct Oura API access.';
  if (service.key === 'github') return 'Repository-scoped access using a fine-grained personal access token.';
  if (service.key === 'tailscale') return 'SSH to your own machines over a private tailnet, one node per resident.';
  return 'Direct external-service access for selected residents.';
}

export function serviceIconClass(serviceKey) {
  if (serviceKey === 'dropbox') return 'bg-blue-600 text-white';
  if (serviceKey === 'google_workspace') return 'bg-green-600 text-white';
  if (serviceKey === 'github') return 'bg-neutral-900 text-white';
  if (serviceKey === 'tailscale') return 'bg-slate-700 text-white';
  return 'bg-red-500 text-white';
}
