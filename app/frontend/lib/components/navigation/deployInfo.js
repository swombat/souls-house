// Turns /admin/deploy_info into the static lines shown in the site-admin menu.
// Deployed and merged are kept separate: a newer merge never implies it is live.

function when(iso) {
  if (!iso) return null;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  return date.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

export function deployLines(info, { failed = false } = {}) {
  if (failed) return [{ text: 'Deploy info unavailable' }];
  if (!info) return [{ text: 'Loading deploy info…' }];

  const lines = [];
  const deployed = info.deployed;
  if (deployed) {
    const booted = when(deployed.booted_at);
    lines.push({
      text: `Deployed ${deployed.short}${deployed.dirty ? ' (uncommitted)' : ''}${booted ? ` · up ${booted}` : ''}`,
      title: deployed.sha,
    });
  } else {
    lines.push({ text: 'Deployed: unknown (no build revision)' });
  }

  const master = info.master;
  if (master) {
    const merged = when(master.committed_at);
    lines.push({
      text: `Last merged ${master.short}${merged ? ` · ${merged}` : ''}`,
      title: [master.sha, master.message].filter(Boolean).join(' — '),
    });
  } else {
    lines.push({ text: 'Last merged: unknown (GitHub unreachable)' });
  }

  if (info.behind_by === 0) lines.push({ text: 'Live build is up to date with master' });
  else if (Number.isInteger(info.behind_by) && info.behind_by > 0)
    lines.push({ text: `Live build is ${info.behind_by} commit${info.behind_by === 1 ? '' : 's'} behind master` });

  return lines;
}
