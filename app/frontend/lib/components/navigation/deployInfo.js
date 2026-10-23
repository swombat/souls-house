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
    // Commit time, not merge time: direct pushes and fast-forwards keep the
    // original commit date, so this must not be presented as "merged at".
    const merged = when(master.committed_at);
    lines.push({
      text: `Master ${master.short}${merged ? ` · committed ${merged}` : ''}`,
      title: [master.sha, master.message].filter(Boolean).join(' — '),
    });
  } else {
    lines.push({ text: 'Master: unknown (GitHub unreachable)' });
  }

  if (info.behind_by === 0) lines.push({ text: 'Live build is up to date with master' });
  else if (Number.isInteger(info.behind_by) && info.behind_by > 0)
    lines.push({ text: `Live build is ${info.behind_by} commit${info.behind_by === 1 ? '' : 's'} behind master` });

  // The deploy alarm's verdict, when it has one worth saying.
  const alarm = info.alarm;
  if (alarm?.stale) lines.push({ text: "Deploy alarm: hasn't checked lately", title: alarm.reason });
  else if (alarm?.state === 'stuck')
    lines.push({ text: 'Deploy alarm: production has stopped following master', title: alarm.reason });
  else if (alarm?.state === 'unknown' && alarm.banner)
    lines.push({ text: "Deploy alarm: can't tell whether production follows master", title: alarm.reason });

  return lines;
}

// The little mark on the Site Admin button: a green tick when the live build
// is master, an orange count of commits behind, a grey question mark when it
// can't be told (GitHub unreachable, uncommitted or off-master build). Nothing
// while the first answer is loading. `deploying` (CI or a deploy running on
// master) puts a spinner round it.
export function deployBadge(info, { failed = false } = {}) {
  if (!info && !failed) return null;
  const deploying = info?.deploying === true;
  const suffix = deploying ? ' · CI or a deploy is running' : '';
  const behind = info?.behind_by;
  if (!failed && behind === 0) return { kind: 'current', deploying, title: `Up to date with master${suffix}` };
  if (!failed && Number.isInteger(behind) && behind > 0)
    return {
      kind: 'behind',
      count: behind,
      deploying,
      title: `${behind} commit${behind === 1 ? '' : 's'} behind master${suffix}`,
    };
  const why = failed
    ? 'Deploy info unavailable'
    : !info.master
      ? 'GitHub unreachable'
      : !info.deployed
        ? 'No build revision'
        : info.deployed.dirty
          ? 'Uncommitted build'
          : 'Can’t compare the live build with master';
  return { kind: 'unknown', deploying, title: `${why}${suffix}` };
}

// Calls load() now, then again after delay() ms each time it settles, until
// the returned stop() is called. stop() also covers a load still in flight
// when it is called: nothing is scheduled after it, so an unmounted menu
// leaves no poller behind.
export function startPolling(load, delay) {
  let disposed = false;
  let timer;
  const run = async () => {
    try {
      await load();
    } finally {
      if (!disposed) timer = setTimeout(run, delay());
    }
  };
  run();
  return () => {
    disposed = true;
    clearTimeout(timer);
  };
}
