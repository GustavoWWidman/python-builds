# python-builds — a "Python foundry" for EOL CPython on macOS

GitHub Actions that build **relocatable, native CPython** for end-of-life Python
versions that macOS runners (and python-build-standalone / uv) no longer
prebuild, publish them as **GitHub Releases**, and are consumed by
[`mise`](https://mise.jdx.dev) as a **version of its core `python` tool** via a
pyenv/python-build definition (`"copy"` mode) — see
[Consuming from mise](#consuming-from-mise-the-single-python-tool-model).

The motivating target is **CPython 3.6.15 on Apple Silicon**, for which there is
no prebuilt binary anywhere:

- python-build-standalone (what mise/uv download) starts at **3.8**.
- python.org's last macOS 3.6 binary was **3.6.8 (Intel only)**.

So we build 3.6 from source on an arm64 runner.

## Quick start — install CPython 3.6.15 with mise

Once a release exists (see [How to trigger a build](#how-to-trigger-a-build)),
one command wires it into `mise` as a normal `python` version:

```bash
# grab bootstrap.sh from this repo (or clone the repo), then:
curl -fsSLO https://raw.githubusercontent.com/GustavoWWidman/python-builds/main/bootstrap.sh
chmod +x bootstrap.sh
PYBUILDS_REPO=GustavoWWidman/python-builds ./bootstrap.sh 3.6.15

mise install python@3.6.15      # downloads the prebuilt — no compile
```

`bootstrap.sh` detects your arch, resolves the matching release asset and its
published `sha256`, writes the python-build definition to
`~/.config/mise/python-build-defs/3.6.15`, and adds `PYTHON_BUILD_DEFINITIONS` to
your mise config (idempotent, backs up first). Afterward `python@3.6.15` is just
another version of mise's **one** `python` tool — beside the precompiled
3.11 / 3.14 — selectable via `python = "3.6.15"` or a `.python-version`:

```bash
echo 3.6.15 > .python-version   # this dir now uses 3.6.15
mise use python@3.11            # elsewhere, still the fast precompiled build
```

That's the whole from-scratch flow. The section
[Consuming from mise](#consuming-from-mise-the-single-python-tool-model) below
explains what the bootstrap does under the hood and the manual equivalent.

## Why this is not just "./configure && make"

Python 3.6 predates OpenSSL 3, and this is the whole reason the project exists:

- **3.6 needs OpenSSL 1.1.1.** Its `_ssl` / `_hashlib` are only ABI-correct
  against **OpenSSL 1.1.x**. Built against OpenSSL 3 they *compile*, but
  `ssl.getpeercert()` returns empty and TLS verification silently breaks.
- **Homebrew removed `openssl@1.1`.** `brew install openssl@1.1` fails on current
  runners, so the workflow **builds OpenSSL 1.1.1w from source**
  (`scripts/build-openssl.sh`) into a staging prefix.
- **3.6's `configure` has no `--with-openssl`** (added in 3.7). We wire the
  from-source OpenSSL in through `CPPFLAGS`/`LDFLAGS`/`LD_LIBRARY_PATH` so
  `setup.py` autodetects and links **1.1**, then verify with `otool -L` that
  `_ssl` really linked 1.1 and not the system library.

Every other stdlib C-module dependency (zlib, bzip2, xz/lzma, readline, ncurses,
gdbm, libffi) is taken from Homebrew — **only `openssl@1.1` is the problem**.

- **A CA trust store ships inside the tarball.** The from-source OpenSSL's
  compiled-in cert path points at the build machine, so a stock relocated tree
  has *no* trust roots and TLS fails with `CERTIFICATE_VERIFY_FAILED`. The build
  therefore bundles a CA bundle at `ssl/cert.pem` and installs a
  `sitecustomize.py` that sets `SSL_CERT_FILE` to it (relative to `sys.prefix`)
  at interpreter startup — so **TLS verifies out of the box, wherever the tree
  is extracted, with no environment setup**. Set your own `SSL_CERT_FILE` to
  override (e.g. to point at a corporate bundle); an explicit value always wins.

## How to trigger a build

Actions → **build-python** → **Run workflow**, with inputs:

| input             | default   | meaning                              |
| ----------------- | --------- | ------------------------------------ |
| `python_version`  | `3.6.15`  | CPython source version on python.org |
| `openssl_version` | `1.1.1w`  | OpenSSL 1.1.x version to build        |

If you change a version, add its `sha256`+filename line to
`scripts/checksums.txt` (or pass `PYTHON_SHA256` / `OPENSSL_SHA256`), otherwise
the download step fails closed.

## Build pipeline (per matrix target)

`checkout` → `build-openssl.sh` → `build-python.sh` → `relocate.sh` →
`selftest.sh` (**must pass**) → package tarball → publish Release.

The matrix is keyed on target. Today it has one native entry:

| runner     | target triple           | arch    |
| ---------- | ----------------------- | ------- |
| `macos-14` | `aarch64-apple-darwin`  | arm64   |

Adding Intel later is a **one-line matrix addition** (uncomment the `macos-13` →
`x86_64-apple-darwin` block in `.github/workflows/build-python.yml`). Note
`macos-14`/`macos-15` are arm64; `macos-13` is x86_64.

## Release tag & asset naming scheme

- **Tag:** `cpython-v${python_version}` — e.g. `cpython-v3.6.15`.
- **Asset:** `cpython-${python_version}-${target_triple}.tar.gz` — e.g.
  `cpython-3.6.15-aarch64-apple-darwin.tar.gz`.
- **Checksum sidecar:** `<asset>.sha256`.

Multiple targets attach to the same version tag as separate assets. Each tarball
contains a **single top-level directory** named after the asset stem (e.g.
`cpython-3.6.15-aarch64-apple-darwin/`) holding `bin/`, `lib/`, `ssl/`, …. That
wrapper is required by python-build's `"copy"` mode (it renames the first
directory in the archive and copies its contents into the prefix), so a flat
`bin/`-at-root layout would install incorrectly.

## Consuming from mise (the single-`python`-tool model)

The prebuilt tarball is selected as a **version of mise's core `python` tool**,
not as a separate `http:` tool. Under the hood mise's `python` backend is
pyenv/python-build; python-build lets you drop in a custom **definition file**
that installs a version from a prebuilt tarball (`"copy"` mode = download and
copy in as-is, no compile). So `python@3.6.15` becomes just another `python`
version that coexists with the precompiled 3.11 / 3.14 — **one python tool**,
selectable via `python = "..."` in mise config or a `.python-version`.

> **`bootstrap.sh` does steps 1–2 for you** (and fills in the owner + sha256 from
> the release). The manual steps below are for understanding it or customizing.

### 1. Put the definition at a durable path

Copy [`python-build-defs/3.6.15`](python-build-defs/3.6.15) from this repo to a
path **outside mise's cache** (`mise cache clear` wipes the cache, so a
definition living there would vanish):

```bash
mkdir -p ~/.config/mise/python-build-defs
cp python-build-defs/3.6.15 ~/.config/mise/python-build-defs/3.6.15
```

The **filename must equal the mise version string** (`3.6.15`) — python-build
resolves `python@3.6.15` to a definition file literally named `3.6.15`. Edit the
copied file to fill in `<OWNER>` (the GitHub org/user hosting this repo) and
`<SHA256>` (from the release's `<asset>.sha256` sidecar).

### 2. Install once — compile mode scoped to that ONE command

```bash
MISE_PYTHON_COMPILE=1 \
PYTHON_BUILD_DEFINITIONS=~/.config/mise/python-build-defs \
mise install python@3.6.15
```

Scope `MISE_PYTHON_COMPILE=1` to **only this command** — never set it globally,
or 3.11 / 3.14 lose their fast precompiled (python-build-standalone) installs and
start compiling from source. `PYTHON_BUILD_DEFINITIONS` points python-build at
the durable dir so it finds the custom `3.6.15` definition.

### 3. Use it like any other python version

Afterward it is just a normal `python` version. In mise config:

```toml
# mise.toml / ~/.config/mise/config.toml
[tools]
python = "3.6.15"   # alongside e.g. "3.11", "3.14"
```

…or a project `.python-version` of `3.6.15` activates it — one `python` tool,
the precompiled 3.11 / 3.14 and this from-tarball 3.6.15 side by side.

### Caveat

This rests on **pyenv/python-build conventions** (`PYTHON_BUILD_DEFINITIONS`,
the filename==version rule, `"copy"` mode). They are stable and long-standing,
but they are **not a semver-guaranteed mise API** — a future mise/python-build
change could require adjusting the definition or env var.

## Honest status: this is a best-effort first cut

The **relocation step (`relocate.sh`) typically needs 1–2 real CI iterations to
perfect.** Mach-O install-name rewriting is fiddly and depends on the exact set
of `LC_LOAD_DYLIB` entries the toolchain emits on the runner, which is hard to
predict without running there. The build has **not** been run locally (it's for
CI runners). Expect to iterate on the parts called out below.

### Parts most likely to need a real-CI fix

1. **`relocate.sh` rpath offsets / load-command set** — the exact dylib
   references (and whether libpython/`_ssl` gain the right `LC_RPATH`) depend on
   what the runner toolchain emits. The verify gate will *tell you* if an
   absolute path survived, but the fix may need extra `-change`/`-add_rpath`.
2. **arm64 support in 3.6's `configure`** — 3.6 predates Apple Silicon; we
   refresh `config.guess`/`config.sub`, but additional source patches (or a
   specific SDK/deployment target) may be needed for a clean compile.
3. **`setup.py` OpenSSL detection** — 3.6 finds ssl via `CPPFLAGS`/`LDFLAGS`;
   if `_ssl`/`_hashlib` don't build or link the *system* OpenSSL, you may need to
   patch `setup.py`/`Modules/Setup` to force the staging prefix.
4. **Upstream checksums** — verify the `scripts/checksums.txt` values against
   python.org / openssl.org before the first run (see the note in that file).
5. **`--enable-optimizations` (PGO)** — reliable but slow; drop it in
   `build-python.sh` if CI times out.
