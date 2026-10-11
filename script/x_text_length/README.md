# X weighted length patterns

`app/models/x_text_length.rb` ports twitter-text 3.1.0's `parseTweet`. Its regexes
come from the official npm packages (twitter-text 3.1.0, twemoji-parser 11.0.2):

```sh
mkdir /tmp/tt && cd /tmp/tt && echo '{}' > package.json && bun add twitter-text@3.1.0
cp <repo>/script/x_text_length/*.js . && bun dump.js   # writes regexes.json (run from /tmp/tt)
python3 <repo>/script/x_text_length/convert.py <repo>/config/x_text_patterns.json regexes.json
```

`convert.py` rewrites surrogate pairs to code points, `\xHH` to `\u00HH`, JS `^`/`$`
(outside classes) to `\A`/`\z`, and spells out `/i` as explicit case alternatives
(Ruby's `/i` folds ß to "ss"; JavaScript's does not). Do not edit the JSON by hand.

`test/fixtures/files/x_text_length_official.json` holds official results from
`fixture.js`. Before it was trimmed, the port matched the official library on three
random corpora of 31,783 strings each, with no mismatches.
