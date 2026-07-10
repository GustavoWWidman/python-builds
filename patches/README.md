# Source patches

Per-version patches applied to the CPython source before `configure`, keyed by
version (`patches/<python_version>/*.patch`). `build-python.sh` applies every
`.patch` here in sorted order with `patch -p1`.

## 3.6.15

CPython 3.6 predates Apple Silicon and macOS 11, so a stock `configure`/build
fails on an arm64 runner (starting with `configure: error: Unexpected output of
'arch' on OSX`, then ctypes/libffi, `_decimal`, pymalloc alignment, etc.).

These are the exact patches [pyenv](https://github.com/pyenv/pyenv)'s
`python-build` applies to build 3.6.15 natively on arm64 macOS (vendored here so
the build is self-contained). Credit to the pyenv/python-build authors.
