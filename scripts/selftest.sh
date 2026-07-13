#!/usr/bin/env bash
#
# selftest.sh — prove the packaged tarball is relocatable AND that TLS actually
#               works, BEFORE we publish a GitHub Release. Any failure exits
#               non-zero so CI blocks the release step.
#
# WHY EXTRACT TO A DIFFERENT PATH:
#   The whole point of relocate.sh is that the dist works somewhere other than
#   where it was built. We extract into a fresh temp dir that has NOTHING to do
#   with PY_PREFIX, then run the interpreter from there. If any dylib reference
#   still pointed at an absolute build path, `import ssl` would fail here.
#
# THE TLS CHECKS ARE THE REASON THIS PROJECT EXISTS:
#   Against OpenSSL 3, Python 3.6's _ssl compiles but getpeercert() returns
#   empty and verification silently breaks. So we don't just import ssl — we do
#   a real HTTPS fetch and assert getpeercert() is non-empty, and assert the
#   linked OpenSSL is 1.1.1w.
#
# ENV VARS (documented inputs):
#   TARBALL           Path to cpython-*.tar.gz to test.   (REQUIRED)
#   EXPECTED_VERSION  Expected `python3 --version` value. (default: 3.6.15)
#   EXPECTED_OPENSSL  Expected ssl.OPENSSL_VERSION prefix.(default: OpenSSL 1.1.1w)
#   TEST_PIP_PKG      Small pure-python pkg to pip-install(default: six)
#
set -euo pipefail

EXPECTED_VERSION="${EXPECTED_VERSION:-3.6.15}"
EXPECTED_OPENSSL="${EXPECTED_OPENSSL:-OpenSSL 1.1.1w}"
TEST_PIP_PKG="${TEST_PIP_PKG:-six}"

if [[ -z "${TARBALL:-}" || ! -f "${TARBALL}" ]]; then
  echo "ERROR: TARBALL must point at an existing cpython-*.tar.gz" >&2
  exit 2
fi

fail() { echo "SELFTEST FAILURE: $*" >&2; exit 1; }

PY_XY="${EXPECTED_VERSION%.*}"
# Deliberately a different path than the build prefix — proves relocatability.
# EXTRACT_ROOT is the mktemp dir we always clean up; EXTRACT_DIR may descend into
# a wrapper subdir below but the trap must still remove the whole root.
EXTRACT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cpython-selftest.XXXXXX")"
trap 'rm -rf "${EXTRACT_ROOT}"' EXIT
EXTRACT_DIR="${EXTRACT_ROOT}"

echo "==> extracting ${TARBALL} to ${EXTRACT_ROOT} (a path unrelated to the build)"
tar xzf "${TARBALL}" -C "${EXTRACT_ROOT}"

# The tarball has a SINGLE top-level wrapper dir (see the packaging step) so
# python-build's "copy" mode reconstructs the tree correctly. Descend into it so
# the checks below see bin/ lib/ ssl/ at ${EXTRACT_DIR}.
if [[ ! -d "${EXTRACT_DIR}/bin" ]]; then
  sub="$(find "${EXTRACT_DIR}" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -n "${sub}" && -d "${sub}/bin" ]] \
    || fail "tarball layout unexpected: no bin/ at root and no wrapper dir with bin/"
  EXTRACT_DIR="${sub}"
  echo "==> descended into wrapper dir: ${EXTRACT_DIR}"
fi

# The (possibly descended) ${EXTRACT_DIR} now contains bin/ lib/ ... directly.
PYBIN="${EXTRACT_DIR}/bin/python${PY_XY}"
[[ -x "${PYBIN}" ]] || PYBIN="${EXTRACT_DIR}/bin/python3"
if [[ ! -x "${PYBIN}" ]]; then
  echo "ERROR: no python3 executable found under ${EXTRACT_DIR}/bin" >&2
  ls -la "${EXTRACT_DIR}/bin" >&2 || true
  exit 3
fi
echo "==> using interpreter: ${PYBIN}"

# --- 1. version --------------------------------------------------------------
got_version="$("${PYBIN}" --version 2>&1 | awk '{print $2}')"
echo "--> python version: ${got_version}"
[[ "${got_version}" == "${EXPECTED_VERSION}" ]] \
  || fail "version mismatch: got '${got_version}', want '${EXPECTED_VERSION}'"

# --- 1.5 bare `python` entry point (the mise copy-mode contract) -------------
# CPython's `make install` ships only python3/pythonX.Y; mise's post-install
# check runs `<prefix>/bin/python --version`, so the tarball MUST include a bare
# `python`. Assert it exists and reports the right version, or copy-mode installs
# fail with ENOENT (regression guard for the build's symlink step).
BARE_PY="${EXTRACT_DIR}/bin/python"
[[ -x "${BARE_PY}" ]] || fail "dist is missing bin/python (mise runs 'bin/python --version')"
bare_version="$("${BARE_PY}" --version 2>&1 | awk '{print $2}')"
[[ "${bare_version}" == "${EXPECTED_VERSION}" ]] \
  || fail "bin/python version mismatch: got '${bare_version}', want '${EXPECTED_VERSION}'"

# --- 2. ssl links OpenSSL 1.1.1w ---------------------------------------------
got_openssl="$("${PYBIN}" -c 'import ssl; print(ssl.OPENSSL_VERSION)')"
echo "--> ssl.OPENSSL_VERSION: ${got_openssl}"
[[ "${got_openssl}" == "${EXPECTED_OPENSSL}"* ]] \
  || fail "OpenSSL mismatch: got '${got_openssl}', want prefix '${EXPECTED_OPENSSL}' (OpenSSL 3 => broken TLS)"

# --- 2.5 bundled CA store present + auto-wired (zero-config trust) ------------
# The from-source OpenSSL has no usable default cert path, so the dist ships a
# CA bundle and a sitecustomize.py that auto-sets SSL_CERT_FILE relative to
# sys.prefix. Prove BOTH here: the bundle exists in the (relocated) tree, and a
# fresh interpreter auto-populates SSL_CERT_FILE to an existing file — WITHOUT
# us exporting it. This is what makes the HTTPS check below pass zero-config.
[[ -f "${EXTRACT_DIR}/ssl/cert.pem" ]] || fail "dist is missing bundled ssl/cert.pem"
auto_cert="$(env -u SSL_CERT_FILE "${PYBIN}" -c 'import os; print(os.environ.get("SSL_CERT_FILE",""))')"
echo "--> auto SSL_CERT_FILE: ${auto_cert}"
[[ "${auto_cert}" == "${EXTRACT_DIR}/ssl/cert.pem" && -f "${auto_cert}" ]] \
  || fail "sitecustomize did not auto-set SSL_CERT_FILE to the in-tree bundle (got '${auto_cert}')"

# --- 3. real HTTPS fetch + non-empty peer cert -------------------------------
# This is the check that catches the OpenSSL-3 ABI bug: getpeercert() must be
# non-empty and verification must succeed against a real endpoint.
# Run with SSL_CERT_FILE/SSL_CERT_DIR SCRUBBED so verification is forced through
# sitecustomize + the in-tree ssl/cert.pem — otherwise a runner that exports its
# own bundle could make this pass without ever exercising the shipped certs
# (the exact zero-config guarantee a consumer on a clean machine depends on).
env -u SSL_CERT_FILE -u SSL_CERT_DIR "${PYBIN}" - <<'PYEOF' || fail "HTTPS fetch / getpeercert verification failed"
import ssl, socket, sys
import urllib.request

url = "https://pypi.org/simple/"
ctx = ssl.create_default_context()

# 3a. real end-to-end HTTPS request must return 200.
resp = urllib.request.urlopen(url, timeout=30, context=ctx)
assert resp.status == 200, "unexpected HTTP status: %r" % resp.status

# 3b. getpeercert() must be non-empty — empty means the OpenSSL-3 ABI bug.
host = "pypi.org"
with socket.create_connection((host, 443), timeout=30) as sock:
    with ctx.wrap_socket(sock, server_hostname=host) as ssock:
        cert = ssock.getpeercert()
assert cert, "getpeercert() returned empty — TLS verification is silently broken"
assert cert.get("subject"), "peer cert has no subject — broken"
print("--> HTTPS 200 OK; getpeercert() subject:", cert["subject"])
PYEOF

# --- 3.5 stdlib C-extension import smoke test --------------------------------
# Each module below is a compiled C extension that links a brew/vendored dylib
# (or OpenSSL). If relocate.sh dropped or mis-wired one, the import fails here
# and we block the release — fail-closed. curses / readline / dbm.gnu are kept
# REQUIRED (not optional) because the behave use-case relies on them; the second
# `ssl` in the spec is deduped since section 2 already asserts it links 1.1.
echo "--> importing required stdlib C extensions"
"${PYBIN}" - <<'PYEOF' || fail "a required stdlib C extension is missing or unloadable"
import importlib, sys

required = ["ssl", "bz2", "lzma", "zlib", "ctypes", "sqlite3",
            "readline", "curses", "dbm.gnu", "hashlib"]
missing = []
for name in required:
    try:
        importlib.import_module(name)
    except Exception as exc:
        missing.append("%s (%s)" % (name, exc))
if missing:
    print("MISSING/UNLOADABLE:", ", ".join(missing), file=sys.stderr)
    sys.exit(1)
print("--> all required stdlib C extensions imported OK:", ", ".join(required))
PYEOF

# --- 4. pip install a small pure-python package ------------------------------
echo "--> pip install ${TEST_PIP_PKG} into an isolated target"
PIP_TARGET="$(mktemp -d "${TMPDIR:-/tmp}/cpython-piptest.XXXXXX")"
trap 'rm -rf "${EXTRACT_ROOT}" "${PIP_TARGET}"' EXIT
"${PYBIN}" -m pip install --quiet --disable-pip-version-check \
  --target "${PIP_TARGET}" "${TEST_PIP_PKG}" \
  || fail "pip install ${TEST_PIP_PKG} failed"
PYTHONPATH="${PIP_TARGET}" "${PYBIN}" -c "import ${TEST_PIP_PKG}; print('--> imported', '${TEST_PIP_PKG}', 'OK')" \
  || fail "could not import ${TEST_PIP_PKG} after install"

echo "==> ALL SELFTESTS PASSED — safe to publish."
