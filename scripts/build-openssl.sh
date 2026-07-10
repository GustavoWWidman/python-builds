#!/usr/bin/env bash
#
# build-openssl.sh — build a RELOCATABLE OpenSSL 1.1.1 into a staging prefix.
#
# WHY THIS SCRIPT EXISTS (read before touching):
#   Python 3.6 predates OpenSSL 3. Its _ssl / _hashlib modules are only
#   ABI-correct against OpenSSL 1.1.x. If you link them against OpenSSL 3,
#   _ssl compiles fine but ssl.getpeercert() returns empty and TLS verification
#   silently breaks. Homebrew has REMOVED the openssl@1.1 formula, so we cannot
#   `brew install openssl@1.1` on current runners — we must build 1.1.1w from
#   source here. This install goes into its OWN staging prefix (OPENSSL_PREFIX),
#   NOT the Python prefix; relocate.sh later copies the two dylibs into the
#   Python tree and rewrites their install names.
#
# ENV VARS (documented inputs):
#   OPENSSL_VERSION   OpenSSL version to build.        (default: 1.1.1w)
#   OPENSSL_PREFIX    Staging install prefix.          (REQUIRED)
#   OPENSSL_ARCH      OpenSSL Configure target.        (default: darwin64-arm64-cc)
#                       arm64  -> darwin64-arm64-cc
#                       x86_64 -> darwin64-x86_64-cc
#   OPENSSL_SHA256    Override expected source sha256. (default: from checksums.txt)
#   WORK_DIR          Scratch dir for download/build.  (default: mktemp under $TMPDIR)
#   MACOSX_DEPLOYMENT_TARGET  Passed through if set.
#   MAKE_JOBS         Parallel make jobs.              (default: sysctl hw.ncpu)
#
set -euo pipefail

OPENSSL_VERSION="${OPENSSL_VERSION:-1.1.1w}"
OPENSSL_ARCH="${OPENSSL_ARCH:-darwin64-arm64-cc}"
OPENSSL_SHA256="${OPENSSL_SHA256:-}"
MAKE_JOBS="${MAKE_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

if [[ -z "${OPENSSL_PREFIX:-}" ]]; then
  echo "ERROR: OPENSSL_PREFIX is required (staging prefix, must NOT be the Python prefix)." >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKSUMS_FILE="${SCRIPT_DIR}/checksums.txt"
WORK_DIR="${WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/openssl-build.XXXXXX")}"
TARBALL="openssl-${OPENSSL_VERSION}.tar.gz"

echo "==> Building OpenSSL ${OPENSSL_VERSION} (${OPENSSL_ARCH}) into ${OPENSSL_PREFIX}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# --- Resolve expected checksum ------------------------------------------------
# Prefer an explicit env override; otherwise look the file up in checksums.txt.
if [[ -z "${OPENSSL_SHA256}" ]]; then
  OPENSSL_SHA256="$(awk -v f="${TARBALL}" '$2==f {print $1}' "${CHECKSUMS_FILE}" || true)"
fi
if [[ -z "${OPENSSL_SHA256}" ]]; then
  echo "ERROR: no expected sha256 for ${TARBALL}. Add it to ${CHECKSUMS_FILE} or set OPENSSL_SHA256." >&2
  exit 3
fi

# --- Download (openssl.org primary, GitHub release mirror as fallback) --------
# 1.1.1w currently lives in /source/; older point releases move to /source/old/.
URLS=(
  "https://www.openssl.org/source/${TARBALL}"
  "https://www.openssl.org/source/old/1.1.1/${TARBALL}"
  "https://github.com/openssl/openssl/releases/download/OpenSSL_${OPENSSL_VERSION//./_}/${TARBALL}"
)
downloaded=""
for url in "${URLS[@]}"; do
  echo "--> fetching ${url}"
  if curl -fSL --retry 3 -o "${TARBALL}" "${url}"; then
    downloaded="${url}"
    break
  fi
done
if [[ -z "${downloaded}" ]]; then
  echo "ERROR: failed to download ${TARBALL} from all known URLs." >&2
  exit 4
fi

# --- Verify sha256 (fail closed) ----------------------------------------------
echo "${OPENSSL_SHA256}  ${TARBALL}" | shasum -a 256 -c - \
  || { echo "ERROR: sha256 mismatch for ${TARBALL}"; exit 5; }

# --- Configure / build / install ----------------------------------------------
tar xzf "${TARBALL}"
cd "openssl-${OPENSSL_VERSION}"

# `shared` -> produce libssl.1.1.dylib + libcrypto.1.1.dylib (what Python links).
# `-fPIC`  -> safe for linking into Python's loadable extension modules.
# `no-tests` -> skip the test suite build; we only need the runtime libs.
# We deliberately do NOT install docs/man pages (`install_sw` below).
./Configure "${OPENSSL_ARCH}" \
  --prefix="${OPENSSL_PREFIX}" \
  --openssldir="${OPENSSL_PREFIX}/ssl" \
  shared -fPIC no-tests

make -j"${MAKE_JOBS}"
# install_sw = libraries + headers only (no man pages), which is all Python needs.
make install_sw

echo "==> OpenSSL install-name sanity (should reference ${OPENSSL_PREFIX}; relocate.sh fixes this later):"
otool -D "${OPENSSL_PREFIX}/lib/libssl.1.1.dylib"   || true
otool -D "${OPENSSL_PREFIX}/lib/libcrypto.1.1.dylib" || true

echo "==> OpenSSL ${OPENSSL_VERSION} staged at ${OPENSSL_PREFIX}"
