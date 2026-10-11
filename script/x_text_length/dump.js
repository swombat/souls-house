const fs=require('fs');
const u=require('twitter-text/dist/regexp/extractUrl'); const U=u.default||u;
const g=n=>{const m=require('twitter-text/dist/regexp/'+n);return (m.default||m)};
const out={extractUrl:[U.source,U.flags]};
for (const n of ['invalidUrlWithoutProtocolPrecedingChars','validAsciiDomain','validTcoUrl']) {const r=g(n); out[n]=[r.source,r.flags];}
const cfg=require('twitter-text/dist/configs'); out.config=(cfg.default||cfg).defaults;
const e=require('twemoji-parser/dist/lib/regex'); const E=e.default||e; out.emoji=[E.source,E.flags];
fs.writeFileSync('regexes.json',JSON.stringify(out));
console.log(Object.keys(out), JSON.stringify(out.config).slice(0,400), out.validTcoUrl, out.invalidUrlWithoutProtocolPrecedingChars, out.validAsciiDomain[0].length);
