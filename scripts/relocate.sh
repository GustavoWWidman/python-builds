#!/usr/bin/env bash
#
# relocate.sh — turn the freshly-installed CPython tree into a RELOCATABLE dist.
#
# THE PROBLEM:
#   After build-python.sh, _ssl/_hashlib and (via LDFLAGS) libpython carry
#   absolute LC_LOAD_DYLIB references into $OPENSSL_PREFIX (and Mach-O IDs that
#   point at build-time absolute paths). Ship that tarball to another machine
#   and dyld can't find the libs -> import ssl explodes. We rewrite every
#   absolute build path to a @loader_path/@rpath-relative reference so the tree
#   works wherever it is extracted.
#
#   OpenSSL is not the only offender: stdlib C extensions link OTHER absolute
#   dylibs too (_lzma->liblzma, _gdbm->libgdbm, readline->libreadline, and
#   possibly libffi) by /opt/homebrew/... path. Those escape the OpenSSL-only
#   steps and the selftest, and break on any machine without Homebrew. So after
#   the OpenSSL-specific fixes we run a GENERALIZED pass that walks every Mach-O
#   and vendors ANY non-system dylib (mirroring python-build-standalone).
#
# THE RPATH STRATEGY (why the specific offsets):
#   Layout inside the dist:
#     PREFIX/bin/python3.X                                  (main binary)
#     PREFIX/lib/libpythonX.Ym.dylib                        (shared libpython)
#     PREFIX/lib/libssl.1.1.dylib , libcrypto.1.1.dylib     (bundled here)
#     PREFIX/lib/pythonX.Y/lib-dynload/_ssl*.so, _hashlib*.so
#   We normalize ALL bundled dylib references to @rpath/<name> and then add the
#   correct LC_RPATH per file so @rpath resolves to PREFIX/lib:
#     - bin/python3.X          : @loader_path/../lib          (bin -> lib)
#     - lib/libpython*.dylib   : @loader_path                 (already in lib)
#     - lib-dynload/*.so       : @loader_path/../..           (lib-dynload -> lib)
#   libssl loads libcrypto from the same dir, so @loader_path there too.
#
# ENV VARS (documented inputs):
#   PY_PREFIX         Installed CPython prefix (the tree to fix).  (REQUIRED)
#   OPENSSL_PREFIX    Staging prefix to purge from all load cmds.  (REQUIRED)
#   PYTHON_VERSION    Used to locate libpython / lib-dynload.      (default: 3.6.15)
#   EXTRA_FORBIDDEN   Extra absolute path substring to fail on.    (optional)
#
set -euo pipefail

PYTHON_VERSION="${PYTHON_VERSION:-3.6.15}"

if [[ -z "${PY_PREFIX:-}" ]];      then echo "ERROR: PY_PREFIX is required." >&2;      exit 2; fi
if [[ -z "${OPENSSL_PREFIX:-}" ]]; then echo "ERROR: OPENSSL_PREFIX is required." >&2; exit 2; fi

# X.Y (e.g. 3.6) drives the lib/pythonX.Y and libpythonX.Ym.dylib paths.
PY_XY="${PYTHON_VERSION%.*}"
LIBDIR="${PY_PREFIX}/lib"
DYNLOAD_DIR="${LIBDIR}/python${PY_XY}/lib-dynload"

echo "==> Relocating ${PY_PREFIX} (purging references to ${OPENSSL_PREFIX})"

# Helper: rewrite EVERY LC_LOAD_DYLIB in $1 that contains substring $2, mapping
# it to @rpath/<basename>. Parses `otool -L` (skips the first line = the file).
rewrite_loads_matching() {
  local file="$1" needle="$2" oldref base
  otool -L "${file}" | tail -n +2 | awk '{print $1}' | while read -r oldref; do
    [[ "${oldref}" == *"${needle}"* ]] || continue
    base="$(basename "${oldref}")"
    install_name_tool -change "${oldref}" "@rpath/${base}" "${file}"
    echo "    ${file}: ${oldref} -> @rpath/${base}"
  done
}

# Helper: add an LC_RPATH only if not already present (install_name_tool errors
# on duplicates otherwise).
add_rpath() {
  local file="$1" rp="$2"
  if ! otool -l "${file}" | grep -A2 LC_RPATH | grep -q "path ${rp} "; then
    install_name_tool -add_rpath "${rp}" "${file}"
    echo "    ${file}: +rpath ${rp}"
  fi
}

# Absolute path of the lib dir @rpath must resolve to (canonicalized once).
LIBDIR_ABS="$(cd "${LIBDIR}" && pwd)"

# Helper: is $1 a FOREIGN absolute dylib reference we must vendor? Leave already
# loader-relative refs (@rpath/@loader_path/@executable_path) alone, and leave
# the system libs (/usr/lib, /System) that exist on every macOS. Everything else
# that is an absolute path (Homebrew, /usr/local, the staging prefix) is foreign.
is_foreign_abs() {
  case "$1" in
    @rpath/*|@loader_path/*|@executable_path/*) return 1 ;;
    /usr/lib/*|/System/*)                       return 1 ;;
    /*)                                         return 0 ;;
    *)                                          return 1 ;;
  esac
}

# Helper: compute the @loader_path-relative rpath that points $1 at LIBDIR_ABS,
# based on where the file physically sits in the tree. This GENERALIZES the
# per-file offsets used explicitly below (bin -> ../lib, lib -> ., lib-dynload ->
# ../..) to a Mach-O at any depth, so vendored dylibs get a correct rpath too.
rpath_for_file() {
  local dir; dir="$(cd "$(dirname "$1")" && pwd)"
  local -a fromparts toparts
  IFS='/' read -ra fromparts <<<"${dir#/}"
  IFS='/' read -ra toparts   <<<"${LIBDIR_ABS#/}"
  local i=0
  while [[ ${i} -lt ${#fromparts[@]} && ${i} -lt ${#toparts[@]} \
        && "${fromparts[${i}]}" == "${toparts[${i}]}" ]]; do
    i=$((i + 1))
  done
  local rel="" j
  for ((j = i; j < ${#fromparts[@]}; j++)); do rel="${rel}../"; done
  for ((j = i; j < ${#toparts[@]};   j++)); do rel="${rel}${toparts[${j}]}/"; done
  rel="${rel%/}"
  if [[ -z "${rel}" ]]; then echo "@loader_path"; else echo "@loader_path/${rel}"; fi
}

# Helper: vendor EVERY foreign dylib that $1 loads — copy it into LIBDIR,
# normalize its own ID and the dependent's reference to @rpath/<base>, and give
# the dependent an LC_RPATH that resolves @rpath to LIBDIR. Newly-copied dylibs
# are appended to NEWLY_VENDORED_FILE so the caller can recurse one level (a
# vendored dylib may itself pull in more brew dylibs, e.g. readline -> ncurses).
vendor_foreign_deps() {
  local file="$1" ref base dest changed=0
  while read -r ref; do
    is_foreign_abs "${ref}" || continue
    base="$(basename "${ref}")"
    dest="${LIBDIR}/${base}"
    if [[ ! -f "${dest}" ]]; then
      cp "${ref}" "${dest}"
      chmod u+w "${dest}"
      install_name_tool -id "@rpath/${base}" "${dest}"
      printf '%s\n' "${dest}" >> "${NEWLY_VENDORED_FILE}"
      echo "    vendored ${ref} -> ${dest}"
    fi
    install_name_tool -change "${ref}" "@rpath/${base}" "${file}"
    echo "    ${file}: ${ref} -> @rpath/${base}"
    changed=1
  done < <(otool -L "${file}" | tail -n +2 | awk '{print $1}')
  [[ "${changed}" -eq 1 ]] && add_rpath "${file}" "$(rpath_for_file "${file}")"
  return 0
}

# --- 1. Copy the two OpenSSL dylibs into the Python tree -----------------------
echo "--> copying libssl.1.1 / libcrypto.1.1 into ${LIBDIR}"
cp "${OPENSSL_PREFIX}/lib/libssl.1.1.dylib"    "${LIBDIR}/"
cp "${OPENSSL_PREFIX}/lib/libcrypto.1.1.dylib" "${LIBDIR}/"
chmod u+w "${LIBDIR}/libssl.1.1.dylib" "${LIBDIR}/libcrypto.1.1.dylib"

# --- 2. Fix the OpenSSL dylibs' own IDs and cross-reference -------------------
# Their LC_ID_DYLIB currently points at $OPENSSL_PREFIX. Set to @rpath/<name>.
install_name_tool -id "@rpath/libcrypto.1.1.dylib" "${LIBDIR}/libcrypto.1.1.dylib"
install_name_tool -id "@rpath/libssl.1.1.dylib"    "${LIBDIR}/libssl.1.1.dylib"
# libssl depends on libcrypto (same dir). Point it at a sibling via @loader_path.
otool -L "${LIBDIR}/libssl.1.1.dylib" | tail -n +2 | awk '{print $1}' | while read -r ref; do
  if [[ "${ref}" == *libcrypto.1.1.dylib ]]; then
    install_name_tool -change "${ref}" "@loader_path/libcrypto.1.1.dylib" "${LIBDIR}/libssl.1.1.dylib"
    echo "    libssl: ${ref} -> @loader_path/libcrypto.1.1.dylib"
  fi
done

# --- 3. Fix libpython --------------------------------------------------------
LIBPYTHON="$(find "${LIBDIR}" -maxdepth 1 -name "libpython${PY_XY}*.dylib" | head -n1 || true)"
if [[ -n "${LIBPYTHON}" ]]; then
  install_name_tool -id "@rpath/$(basename "${LIBPYTHON}")" "${LIBPYTHON}"
  rewrite_loads_matching "${LIBPYTHON}" "${OPENSSL_PREFIX}"
  add_rpath "${LIBPYTHON}" "@loader_path"
fi

# --- 4. Fix the main python binary -------------------------------------------
# It loads libpython by absolute build path; rewrite to @rpath and add rpath.
for bin in "${PY_PREFIX}/bin/python${PY_XY}" "${PY_PREFIX}/bin/python${PY_XY}m"; do
  [[ -f "${bin}" ]] || continue
  otool -L "${bin}" | tail -n +2 | awk '{print $1}' | while read -r ref; do
    if [[ "${ref}" == *"libpython${PY_XY}"*.dylib ]]; then
      install_name_tool -change "${ref}" "@rpath/$(basename "${ref}")" "${bin}"
      echo "    ${bin}: ${ref} -> @rpath/$(basename "${ref}")"
    fi
  done
  rewrite_loads_matching "${bin}" "${OPENSSL_PREFIX}"
  add_rpath "${bin}" "@loader_path/../lib"
done

# --- 5. Fix _ssl / _hashlib (and any other extension pulling in OpenSSL) ------
if [[ -d "${DYNLOAD_DIR}" ]]; then
  while IFS= read -r ext; do
    # Does this extension reference the staging OpenSSL at all?
    if otool -L "${ext}" | tail -n +2 | awk '{print $1}' | grep -q "${OPENSSL_PREFIX}"; then
      rewrite_loads_matching "${ext}" "${OPENSSL_PREFIX}"
      # lib-dynload -> lib is two levels up.
      add_rpath "${ext}" "@loader_path/../.."
    fi
  done < <(find "${DYNLOAD_DIR}" -name "*.so")
fi

# --- 6. GENERALIZED VENDORING: catch every foreign dylib, not just OpenSSL -----
# Walk every Mach-O in the tree and vendor ANY non-system absolute dylib the
# OpenSSL-specific steps above didn't touch (liblzma, libgdbm, libreadline,
# libncurses, libffi, ...). Without this they stay as /opt/homebrew refs, sail
# past the gate below only because it used to list OpenSSL alone, and blow up on
# a Homebrew-less machine.
echo "--> generalized vendoring of all foreign (non-system) dylibs"
NEWLY_VENDORED_FILE="$(mktemp "${TMPDIR:-/tmp}/relocate-vendored.XXXXXX")"
trap 'rm -f "${NEWLY_VENDORED_FILE}"' EXIT

list_machos() {
  find "${PY_PREFIX}/bin" -type f 2>/dev/null || true
  find "${LIBDIR}" \( -name "*.dylib" -o -name "*.so" \) -type f 2>/dev/null || true
}

# Level 0: every Mach-O already in the tree.
while IFS= read -r macho; do
  file "${macho}" 2>/dev/null | grep -q 'Mach-O' || continue
  vendor_foreign_deps "${macho}"
done < <(list_machos)

# Level 1: dylibs we just vendored may themselves depend on more brew dylibs.
# Snapshot the list first (recurse exactly one level, deterministically).
FIRST_LEVEL=()
while IFS= read -r vend; do FIRST_LEVEL+=("${vend}"); done < "${NEWLY_VENDORED_FILE}"
for vend in "${FIRST_LEVEL[@]}"; do
  [[ -f "${vend}" ]] || continue
  vendor_foreign_deps "${vend}"
done

# --- 7. RE-SIGN: install_name_tool invalidates code signatures ----------------
# On Apple Silicon, an unsigned or signature-invalid Mach-O is SIGKILL'd at exec
# by the kernel. Every rewrite above broke the original ad-hoc signature, so we
# ad-hoc re-sign every Mach-O in the tree before shipping.
echo "==> ad-hoc re-signing every Mach-O (arm64 rejects invalid signatures at exec)"
while IFS= read -r macho; do
  file "${macho}" 2>/dev/null | grep -q 'Mach-O' || continue
  codesign -s - -f "${macho}" 2>/dev/null || echo "    WARN: codesign failed for ${macho}"
done < <(list_machos)

# --- 8. VERIFY: no non-system absolute path may remain anywhere ---------------
# Fail the build if any Mach-O still references a foreign absolute prefix. After
# the generalized vendoring in step 6 nothing should; if anything does, the tree
# is NOT relocatable and we must block the release. All matches use grep -F
# (fixed-string) so path metacharacters can't be misread as regex.
echo "==> verifying no non-system absolute paths remain in the shipped tree"
FORBIDDEN=("${OPENSSL_PREFIX}" "${PY_PREFIX}" "/opt/homebrew" "/usr/local")
[[ -n "${EXTRA_FORBIDDEN:-}" ]] && FORBIDDEN+=("${EXTRA_FORBIDDEN}")
violations=0
while IFS= read -r macho; do
  # Only inspect Mach-O files (dylibs + .so + executables).
  file "${macho}" | grep -q 'Mach-O' || continue
  loads="$(otool -L "${macho}" 2>/dev/null | tail -n +2 || true)"
  for bad in "${FORBIDDEN[@]}"; do
    if grep -qF "${bad}" <<<"${loads}"; then
      echo "  VIOLATION: ${macho} still references ${bad}" >&2
      grep -F "${bad}" <<<"${loads}" >&2
      violations=$((violations + 1))
    fi
  done
done < <(find "${PY_PREFIX}" \( -name "*.dylib" -o -name "*.so" -o -perm -u+x -type f \))

if [[ "${violations}" -gt 0 ]]; then
  echo "ERROR: ${violations} absolute build-path reference(s) remain; tree is NOT relocatable." >&2
  exit 6
fi

echo "==> relocation complete; tree is self-contained."
