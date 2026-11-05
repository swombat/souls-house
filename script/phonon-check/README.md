# Phonon in a real browser

A manual check of the voice engine outside the Rails app: the real
`app/frontend/lib/phonon-engine.js`, the patched `phonon-webgpu`, and the files in
`public/phonon-assets`, in Playwright's Chromium. Run it after changing a pin in
`config/phonon_assets.json` or bumping the library.

```sh
ruby bin/phonon-assets
mkdir -p tmp/phonon-check && cp script/phonon-check/entry.js app/frontend/__phonon_check.js
bun build app/frontend/__phonon_check.js --outdir tmp/phonon-check --format esm --target browser --splitting
rm app/frontend/__phonon_check.js
cd tmp/phonon-check && mv __phonon_check.js bundle.js && ln -sfn ../../public/phonon-assets phonon-assets
printf '<!doctype html><script type="module" src="/bundle.js"></script>\n' > index.html
python3 -m http.server 8765 --bind 127.0.0.1 &   # localhost counts as a secure context
cd ../.. && node script/phonon-check/drive.mjs    # FLAGS, PROFILE, TEXT, PORT override
```

Without a GPU, the default flags give Chromium SwiftShader's software WebGPU adapter:
the output proves the pipeline (files from this site only, the Cache Storage keys,
the state sequence, the audio length), not speed. Run it twice with the same PROFILE
to see a revisit load from the cache with no downloads; `FLAGS=--disable-gpu` shows
the no-WebGPU error with nothing downloaded.
