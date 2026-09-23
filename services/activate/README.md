# kiddyproof — activation service

Turns a **Creem** purchase into the key the **app** understands.

A buyer finishes checkout and Creem returns them here, appending `checkout_id`.
This service looks that checkout up server-side with the Creem API key, confirms
it is paid and for our product, takes the buyer's email, and mints an
Ed25519-signed `KIDDY.<payload>.<signature>` — the format
`Sources/KiddyproofCore/License.swift` verifies **offline**.

Looking the checkout up beats trusting a licence key in the query string: a
`checkout_id` on its own is useless to anyone without our API key.

## Why the exchange, instead of teaching the app to speak Creem

Everyone who already downloaded kiddyproof can buy and activate on the build
they already have — no update required — and the app keeps verifying offline
with no phone-home. A store can only ever issue keys in its own format, so
something has to do the conversion.

## Endpoints

| Path                | What it does                                              |
|---------------------|-----------------------------------------------------------|
| `GET /activate?checkout_id=…` | Verifies the purchase, returns a page that deep-links the key into the app |
| `GET /activate?k=…` | Redeems a Creem **store** key directly — the recovery path for anyone who lost the success page |
| `GET /activate`     | No params: renders the paste-your-key form that feeds the line above |
| `GET /health`       | `{"ok","signingKey","canMint","creemApiKey","creemApiBase","productGuard"}` — never reveals the key |
| `GET /fonts/*`      | Self-hosted woff2 so the page matches the site             |

Redemption goes through Creem's **activate** endpoint, not **validate**:
`validate` requires an `instance_id` you don't have yet and returns no customer
email. Activation is also what enforces the issue cap — Creem counts each
activation against the licence's limit, so a key that has been redeemed its
allowed number of times stops minting.

## Environment variables

| Name                   | Required | Notes                                                      |
|------------------------|----------|------------------------------------------------------------|
| `LICENSE_PRIVATE_KEY`  | yes      | base64 of the 32-byte Ed25519 seed — same value as `secrets/license_private.key`. **Set it in the Railway dashboard, never on a command line.** |
| `CREEM_API_KEY`        | **yes**  | Creem dashboard → Settings → API keys. The API host is derived from it: a key containing `test` uses `test-api.creem.io`, anything else uses `api.creem.io`, so there is no second variable to forget when going live. |
| `CREEM_PRODUCT_ID`     | no       | e.g. `prod_6As46kddvHUj4A4pnaYMD8`; when set, a purchase of any other product is refused |
| `PORT`                 | no       | provided by Railway                                        |

Without `CREEM_PRODUCT_ID`, a paid checkout for *any* product in this Creem store
would mint a kiddyproof key — **set it before going live.** `/health` reports the
state of both variables so the gap stays visible.

## Deploy (Railway, project `kiddyproof`)

```sh
railway add --service activate                              # once
railway up --service activate --path-as-root services/activate
railway domain --service activate                           # generates the public URL
```

**Run these from the repo root, and do not drop `--path-as-root`.** `railway up`
archives from the linked *project* root regardless of your shell's directory, so
without it the repo's `Staticfile` wins and Railpack builds a Caddy static site
instead of this Node app. (Equivalently: set the service's Root Directory to
`services/activate` in the dashboard.) Also do not re-add `services/` to
`.railwayignore` — that silently strips this code out of the upload.

Then in the Railway dashboard → `activate` → Variables, add
`LICENSE_PRIVATE_KEY` (and the two ids once known).

The service is reached at **`https://activate.kiddyproof.app`** (Cloudflare CNAME
`activate` → the Railway target, **DNS-only**, plus the `_railway-verify.activate`
TXT record Railway requires before it will issue the certificate — the CLI only
ever prints the CNAME, so take both records from the dashboard's *Show DNS
records*). `kiddyproof.app/activate` is a static page in `site/` that forwards
here preserving the query string; it is the address the app's own error dialog
gives people.

Finally, point Creem at it: the product's `default_success_url` must be
`https://activate.kiddyproof.app/activate` — Creem appends `checkout_id`. The
dashboard drawer is awkward to reach, so set it over the API:

```sh
curl -X PATCH https://api.creem.io/v1/products/<product_id> \
  -H "x-api-key: $CREEM_API_KEY" -H 'Content-Type: application/json' \
  -d '{"default_success_url":"https://activate.kiddyproof.app/activate"}'
```

(`POST`/`PUT` on that path both 404 — only `PATCH` updates a product.) Read it
back with `GET /v1/products?product_id=<product_id>`. The service's previous
`*.up.railway.app` host stays attached and keeps working, so links already in
buyers' hands don't break.

## Verifying a minted key really works

`npm run verify-key` mints a key and checks it against the app's *actual*
`License.swift`, including that a tampered key is rejected.

## Rotating the signing key

Changing it invalidates every key already issued, so it is only cheap while no
licenses are in the wild. Run `swift Scripts/make_license.swift generate-keys`
(it refuses to overwrite an existing key), paste the new public key into
`License.publicKeyB64`, ship an app release, and update `LICENSE_PRIVATE_KEY`
here.
