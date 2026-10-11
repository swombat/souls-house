// Writes official twitter-text 3.1.0 results for a corpus (JSON array of
// strings on stdin) as [[text, weightedLength, valid], ...] on stdout.
const tt = require('twitter-text');
const cases = JSON.parse(require('fs').readFileSync(0, 'utf8'));
console.log(JSON.stringify(cases.map((t) => { const r = tt.parseTweet(t); return [t, r.weightedLength, r.valid]; })));
