# Go-live checklist

Takes this repo from scaffold → a working `mise`-managed `python@3.6.15` on your
machine. Nothing below has run yet; do it in order. Replace `<OWNER>` throughout
with your GitHub org/user.

## 1. Pin the release action (security)
In `.github/workflows/build-python.yml`, replace `<PIN-TO-SHA>` with the real
40-char commit SHA of `softprops/action-gh-release` at v2.x.x (grab it from the
action's releases page). Mutable tags on a `contents: write` action are a
supply-chain risk.

## 2. Verify the Python source checksum (one-time)
Confirm the `Python-3.6.15.tar.xz` sha256 in `scripts/checksums.txt` matches
python.org before the first run (the OpenSSL 1.1.1w hash is already the published
value). Fail-closed downloads are only as good as these hashes.

## 3. Create + push the repo
```bash
cd ~/GitHub/python-builds
jj git init --colocate            # jj is the VCS of record here (or: git init)
jj describe -m "feat: cpython foundry — relocatable native builds for EOL versions"
# create the GitHub repo and push (gh CLI):
gh repo create <OWNER>/python-builds --private --source=. --push
```
(Do NOT commit build artifacts — `.gitignore` already excludes `build/`, `dist/`,
`*.tar.gz`, `*.sha256`.)

## 4. Trigger the first build
```bash
gh workflow run build-python.yml -f python_version=3.6.15
gh run watch                      # the selftest step GATES the release
```
Expect the first run to need 1–2 iterations on `relocate.sh` (the runner's exact
load-command/rpath output is unknowable until it runs — see README). The build
will NOT publish a release unless the selftest passes.

## 5. Confirm the release
```bash
gh release view cpython-v3.6.15 --repo <OWNER>/python-builds
# expect assets: cpython-3.6.15-aarch64-apple-darwin.tar.gz  +  .sha256
```

## 6. Wire it into mise (one command)
```bash
PYBUILDS_REPO=<OWNER>/python-builds ~/GitHub/python-builds/bootstrap.sh 3.6.15
mise install python@3.6.15        # downloads the prebuilt, no compile
# verify:
mise exec python@3.6.15 -- python -c \
  "import ssl,urllib.request as u; print(ssl.OPENSSL_VERSION); print(u.urlopen('https://pypi.org/simple/').status)"
# expect: OpenSSL 1.1.1w …   /   200
```

## 7. Switch over + retire any local from-source build (phased — only after 6 passes)
- Projects that select 3.6.15 via `.python-version` (or `python = "3.6.15"`) are now
  served by the prebuilt automatically — no change needed in them.
- If you previously built 3.6.15 from source via a mise `install_env` apparatus
  (custom OpenSSL 1.1 wiring, a `brew` shim, pkgx build deps), you can remove that
  now — 3.6.15 no longer compiles locally. Keep `3.6.15` in your `python` versions;
  it resolves to the prebuilt. Only drop shared build deps if nothing else uses them.

## Rollback
If the prebuilt misbehaves: delete `~/.config/mise/python-build-defs/3.6.15` (or
unset `PYTHON_BUILD_DEFINITIONS`) and reinstall — any previous from-source setup
builds 3.6.15 as before. Keep that fallback in place until you've trusted the
prebuilt for a while.

## Adding more versions / arches later
- Another EOL version: `gh workflow run build-python.yml -f python_version=3.7.17`,
  then `bootstrap.sh 3.7.17`.
- x86_64: uncomment the `macos-13` matrix row in the workflow; the asset name and
  `bootstrap.sh`'s arch detection already handle `x86_64-apple-darwin`.
