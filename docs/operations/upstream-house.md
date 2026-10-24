# Deploying the upstream house

For an existing installation (the upstream house, not a fork): `bin/kamal
deploy` reads `config/deploy.yml`, which is rendered from `config/house.env`
and refuses to render without it. That file is gitignored and lives in the
shared key store as `souls_house.house_env` — materialise it with `keys get
souls_house.house_env > config/house.env` on a fresh clone. Run `bin/house
doctor` to check in one second whether a clone is deploy-ready (keys and
`house.env` both present). The embeddings accessory digest is read from
`house.env` (`HOUSE_EMBEDDINGS_DIGEST`); `MNEMODYNE_EMBEDDING_IMAGE_DIGEST`
is still honoured as an override but no longer needs exporting by hand.

Forks follow [`public/self-host.md`](../../public/self-host.md) instead.
