#!/usr/bin/env bash
#
# build-python.sh — build CPython from source, linked against the staged
#                   OpenSSL 1.1.1 (NOT system OpenSSL / OpenSSL 3).
#
# WHY THE OPENSSL WIRING IS WEIRD (read before touching):
#   Python 3.6's ./configure has NO --with-openssl flag (that arrived in 3.7).
#   So we cannot point configure at our 1.1 build directly. Instead we feed the
#   staged OpenSSL to setup.py's autodetection through the compiler/linker env:
#     CPPFLAGS  -> -I$OPENSSL_PREFIX/include   (so it finds openssl/ssl.h etc.)
#     LDFLAGS   -> -L$OPENSSL_PREFIX/lib       (so _ssl/_hashlib link libssl.1.1)
#   We ALSO bake an rpath of @loader_path/../lib into LDFLAGS so the shipped
#   binaries can find bundled dylibs relative to themselves (see relocate.sh for
#   the full rpath story). After install we print `otool -L` of _ssl*.so so CI
#   logs prove which libssl it actually linked — it MUST be 1.1, not system.
#
# SHARED vs STATIC libpython — decision:
#   We build with --enable-shared (libpythonX.Ym.dylib as a real dylib).
#   Rationale: OpenSSL must ship as dylibs regardless (1.1 is built shared and
#   _ssl/_hashlib load them at runtime), so relocate.sh already has to run
#   install_name_tool over Mach-O objects. Given that machinery exists, shared
#   libpython costs one extra relocation target (bin/python -> @rpath/libpython)
#   but matches what python-build-standalone ships and keeps the dist embeddable.
#   A static libpython (drop --enable-shared) is a valid simpler alternative —
#   it removes that one relocation — but does NOT remove the OpenSSL dylib work,
#   so the net simplification is small. Flip the flag here if you prefer static.
#
# APPLE SILICON / 3.6 CAVEAT:
#   CPython 3.6 predates arm64 macOS. Its bundled config.guess/config.sub don't
#   know aarch64-apple-darwin, so we refresh them from upstream automake before
#   configuring. This is one of the parts most likely to need a real-CI fix.
#
# BREW LIBS ARE FINE (only openssl@1.1 is the problem):
#   zlib, bzip2, xz(lzma), readline, ncurses, gdbm come from Homebrew and are
#   wired via CPPFLAGS/LDFLAGS so the matching stdlib C modules build.
#
# ENV VARS (documented inputs):
#   PYTHON_VERSION    CPython version to build.        (default: 3.6.15)
#   PY_PREFIX         Install prefix = tarball root.   (REQUIRED)
#   OPENSSL_PREFIX    Where build-openssl.sh staged.   (REQUIRED)
#   PYTHON_SHA256     Override expected source sha256. (default: from checksums.txt)
#   WORK_DIR          Scratch dir for download/build.  (default: mktemp)
#   MACOSX_DEPLOYMENT_TARGET  Minimum macOS.           (default: 11.0)
#   MAKE_JOBS         Parallel make jobs.              (default: sysctl hw.ncpu)
#
set -euo pipefail

PYTHON_VERSION="${PYTHON_VERSION:-3.6.15}"
PY_XY="${PYTHON_VERSION%.*}"
PYTHON_SHA256="${PYTHON_SHA256:-}"
CACERT_URL="${CACERT_URL:-https://curl.se/ca/cacert.pem}"
MAKE_JOBS="${MAKE_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

if [[ -z "${PY_PREFIX:-}" ]]; then
  echo "ERROR: PY_PREFIX is required (install prefix; becomes the tarball root)." >&2
  exit 2
fi
if [[ -z "${OPENSSL_PREFIX:-}" ]]; then
  echo "ERROR: OPENSSL_PREFIX is required (must match build-openssl.sh)." >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKSUMS_FILE="${SCRIPT_DIR}/checksums.txt"
WORK_DIR="${WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/python-build.XXXXXX")}"
TARBALL="Python-${PYTHON_VERSION}.tar.xz"

echo "==> Building CPython ${PYTHON_VERSION} into ${PY_PREFIX} (OpenSSL: ${OPENSSL_PREFIX})"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# --- Resolve expected checksum ------------------------------------------------
if [[ -z "${PYTHON_SHA256}" ]]; then
  PYTHON_SHA256="$(awk -v f="${TARBALL}" '$2==f {print $1}' "${CHECKSUMS_FILE}" || true)"
fi
if [[ -z "${PYTHON_SHA256}" ]]; then
  echo "ERROR: no expected sha256 for ${TARBALL}. Add it to ${CHECKSUMS_FILE} or set PYTHON_SHA256." >&2
  exit 3
fi

# --- Download + verify (fail closed) ------------------------------------------
PY_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/${TARBALL}"
echo "--> fetching ${PY_URL}"
curl -fSL --retry 3 -o "${TARBALL}" "${PY_URL}"
echo "${PYTHON_SHA256}  ${TARBALL}" | shasum -a 256 -c - \
  || { echo "ERROR: sha256 mismatch for ${TARBALL}"; exit 5; }

tar xf "${TARBALL}"
cd "Python-${PYTHON_VERSION}"

# --- Apply source patches (arm64 / macOS-11 support) --------------------------
# CPython 3.6 predates Apple Silicon: a stock build fails at `configure`
# ("Unexpected output of 'arch' on OSX") and later in ctypes/libffi, _decimal,
# and pymalloc alignment. We apply the exact patch set pyenv's python-build uses
# (vendored under patches/<version>/), in sorted order, before configure. A
# failed patch aborts the build (set -e).
PATCH_DIR="${SCRIPT_DIR}/../patches/${PYTHON_VERSION}"
if [[ -d "${PATCH_DIR}" ]]; then
  for p in "${PATCH_DIR}"/*.patch; do
    [[ -f "${p}" ]] || continue
    echo "--> applying $(basename "${p}")"
    patch -p1 < "${p}"
  done
else
  echo "WARN: no patches dir ${PATCH_DIR}; a from-source arm64 build of ${PYTHON_VERSION} will likely fail."
fi

# --- Refresh config.guess/config.sub for arm64 awareness ----------------------
# 3.6's vendored copies predate aarch64-apple-darwin; without this, ./configure
# bails with "cannot guess build type". Pull current copies from Homebrew's
# automake share dir if available, else from the GNU savannah mirror.
refresh_gnu_config() {
  local name="$1" dest="$2" brew_share src
  # NB: a glob inside [[ -f ... ]] does NOT expand, so match explicitly via ls
  # and take the first hit (there may be several automake-<ver> dirs).
  if brew_share="$(brew --prefix 2>/dev/null)"; then
    src="$(ls "${brew_share}/share/automake"*/"${name}" 2>/dev/null | head -n1 || true)"
    if [[ -n "${src}" && -f "${src}" ]]; then
      cp "${src}" "${dest}" && return 0
    fi
  fi
  curl -fSL --retry 3 -o "${dest}" \
    "https://git.savannah.gnu.org/cgit/config.git/plain/${name}" && chmod +x "${dest}"
}
refresh_gnu_config config.guess ./config.guess || echo "WARN: could not refresh config.guess"
refresh_gnu_config config.sub   ./config.sub   || echo "WARN: could not refresh config.sub"

# --- Assemble compiler/linker flags -------------------------------------------
# Start with the OpenSSL 1.1 staging prefix, then append each brew lib prefix so
# the matching stdlib modules (zlib, bz2, lzma, readline, curses, dbm) build.
CPPFLAGS="-I${OPENSSL_PREFIX}/include"
# @loader_path/../lib rpath: shipped bin/python is at PREFIX/bin, bundled dylibs
# at PREFIX/lib, so ../lib from the binary resolves to them post-relocation.
LDFLAGS="-L${OPENSSL_PREFIX}/lib -Wl,-rpath,@loader_path/../lib"

add_brew_lib() {
  local formula="$1" p
  if p="$(brew --prefix "${formula}" 2>/dev/null)" && [[ -d "${p}" ]]; then
    CPPFLAGS="${CPPFLAGS} -I${p}/include"
    LDFLAGS="${LDFLAGS} -L${p}/lib"
  else
    echo "WARN: brew formula '${formula}' not found; its stdlib module may be skipped."
  fi
}
# NOTE: intentionally NOT adding openssl here — that must be the from-source 1.1.
for f in zlib bzip2 xz readline ncurses gdbm libffi; do
  add_brew_lib "${f}"
done

export CPPFLAGS LDFLAGS
# setup.py also honors these dir hints when scanning for openssl/other libs.
export LD_LIBRARY_PATH="${OPENSSL_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
export DYLD_LIBRARY_PATH="${OPENSSL_PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"

echo "==> CPPFLAGS=${CPPFLAGS}"
echo "==> LDFLAGS=${LDFLAGS}"

# --- Configure ----------------------------------------------------------------
#   --enable-shared      : build libpython as a dylib (see decision note above).
#   --enable-optimizations: PGO; drop it if build time is a problem on CI.
#   --with-ensurepip     : ship pip so selftest.sh can `pip install`.
#   --enable-ipv6        : needed for the HTTPS selftest on modern networks.
./configure \
  --prefix="${PY_PREFIX}" \
  --enable-shared \
  --enable-optimizations \
  --with-ensurepip=install \
  --enable-ipv6

make -j"${MAKE_JOBS}"
make install

# --- Prove which OpenSSL _ssl actually linked ---------------------------------
# This is the single most important diagnostic line in the whole build. The
# _ssl module MUST reference libssl.1.1 (from our staging prefix at this point,
# rewritten to @rpath by relocate.sh). If it shows system OpenSSL or 3.x, the
# TLS-verification ABI bug is present and selftest.sh will (correctly) fail.
echo "==> otool -L of installed _ssl module(s):"
find "${PY_PREFIX}/lib" -name "_ssl*.so" -print -exec otool -L {} \;
echo "==> otool -L of installed _hashlib module(s):"
find "${PY_PREFIX}/lib" -name "_hashlib*.so" -print -exec otool -L {} \;

# --- Provision a relocatable CA trust store -----------------------------------
# WHY THIS EXISTS:
#   Our OpenSSL 1.1.1w is built from source with an OPENSSLDIR that lives at the
#   staging prefix — a path that does NOT exist on any consumer machine. So the
#   compiled-in default cert file/dir point nowhere and `ssl` has zero trust
#   roots: the TLS handshake succeeds but verification fails with
#   CERTIFICATE_VERIFY_FAILED. We can't `pip install certifi` to fix it either —
#   pip would need working TLS first (chicken-and-egg). Instead we fetch a CA
#   bundle with the runner's `curl` (which trusts the system roots) and ship it
#   inside the tree, then wire `ssl` to it via sitecustomize (below).
echo "==> provisioning bundled CA certificates from ${CACERT_URL}"
mkdir -p "${PY_PREFIX}/ssl"
curl -fSL --retry 3 -o "${PY_PREFIX}/ssl/cert.pem" "${CACERT_URL}"
grep -q "BEGIN CERTIFICATE" "${PY_PREFIX}/ssl/cert.pem" \
  || { echo "ERROR: fetched CA bundle at ${PY_PREFIX}/ssl/cert.pem is not PEM" >&2; exit 7; }

# sitecustomize.py — auto-wire OpenSSL to the bundled store, RELOCATABLY.
#   `site` imports sitecustomize at interpreter startup (before any ssl context
#   is created), so setting SSL_CERT_FILE here makes ssl.create_default_context()
#   / load_default_certs() pick up our bundle. The path is derived from
#   sys.prefix at runtime, so it follows the tree wherever it is extracted.
#   setdefault => an explicit SSL_CERT_FILE from the user still wins.
#   NOTE: site init (hence this file) is skipped under `python -S`/`-I`; those
#   modes must set SSL_CERT_FILE themselves. Fine for the behave use case.
SITE_DIR="${PY_PREFIX}/lib/python${PY_XY}/site-packages"
mkdir -p "${SITE_DIR}"
cat > "${SITE_DIR}/sitecustomize.py" <<'PYEOF'
# Injected by the python-builds foundry. This CPython links an OpenSSL 1.1.1w
# built from source, whose compiled-in cert paths do not exist on this machine.
# Point OpenSSL at the CA bundle shipped inside this tree (prefix/ssl/cert.pem),
# resolved relative to sys.prefix so it keeps working wherever the tree lives.
import os
import sys

_cafile = os.path.join(sys.prefix, "ssl", "cert.pem")
if os.path.isfile(_cafile):
    os.environ.setdefault("SSL_CERT_FILE", _cafile)
PYEOF
echo "==> wrote ${SITE_DIR}/sitecustomize.py (auto SSL_CERT_FILE)"

echo "==> CPython ${PYTHON_VERSION} installed at ${PY_PREFIX}"
