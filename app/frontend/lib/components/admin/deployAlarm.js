// Words for the deploy alarm (DeployAlarm.payload on the server). "No
// information" never reads as "fine": unknown has its own neutral wording.

export function utcTime(iso) {
  if (!iso) return null;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  return `${String(date.getUTCHours()).padStart(2, '0')}:${String(date.getUTCMinutes()).padStart(2, '0')}Z`;
}

function commits(count) {
  return `${count} commit${count === 1 ? '' : 's'}`;
}

// { tone: 'alert' | 'neutral', text } when the banner should show, else null.
export function alarmBanner(alarm) {
  if (!alarm || !alarm.banner) return null;
  const since = utcTime(alarm.since);

  if (alarm.state === 'stuck') {
    const where = alarm.deployed_short ? `Production is on ${alarm.deployed_short}` : 'Production';
    const gap =
      Number.isInteger(alarm.behind_by) && alarm.behind_by > 0
        ? `${commits(alarm.behind_by)} behind master`
        : 'behind master';
    const text = `${where}, ${gap}${since ? ` since ${since}` : ''}.${alarm.reason ? ` ${alarm.reason}` : ''}`;
    return { tone: 'alert', text };
  }

  if (alarm.state === 'unknown') {
    if (alarm.stale) {
      return {
        tone: 'neutral',
        text: `Can't tell whether production follows master: the deploy alarm hasn't checked${since ? ` since ${since}` : ' yet'}.`,
      };
    }
    return {
      tone: 'neutral',
      text: `Can't tell whether production follows master${since ? ` since ${since}` : ''}.${alarm.reason ? ` ${alarm.reason}` : ''}`,
    };
  }

  return null;
}

// The dashboard tile: yes / no since HH:MMZ / unknown.
export function followsMaster(alarm) {
  if (!alarm) return { value: 'unknown', tone: 'neutral' };
  if (alarm.stale) return { value: 'unknown', tone: 'neutral', detail: "the check hasn't run lately" };
  if (alarm.state === 'ok') return { value: 'yes', tone: 'up' };
  if (alarm.state === 'stuck') {
    const since = utcTime(alarm.since);
    return { value: since ? `no since ${since}` : 'no', tone: 'alert', detail: alarm.reason };
  }
  return { value: 'unknown', tone: 'neutral', detail: alarm.reason };
}
