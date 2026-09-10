# Contributing a result

The results database answers, once per chip, "which CPU security features does this device's
kernel expose?" Each file here is one device's full JSON export from Silicon Audit, and the
generated [MATRIX.md](../MATRIX.md) (and the static site) is built from them.

## How to contribute

1. Run Silicon Audit on the device (or `silicon-audit export` on a Mac).
2. Export the **full** JSON (not the compact code) and check the top of the app for a warning
   banner. If it shows Simulator, Rosetta, iOS-on-Mac, or Virtual machine, the numbers describe the
   host, not your device; do not submit them. CI rejects them anyway.
3. Add the file at `results/<identity>/<os_build>-<n>.json`, where `identity` is `device.identity`
   from the export (`Mac17,7`, `iPhone18,2`, `Watch7,1`), `os_build` is `environment.os_build`
   (`25G83`), and `n` is the next free sequence number for that build (start at 1).
4. Open a pull request. CI validates the file against `Schema/export-v1.schema.json` (which is also
   the privacy allowlist: only the approved sysctl keys may appear), checks the path, and
   regenerates the matrix.

## What the file contains, and does not

The export carries measured sysctl readings, Apple's documented claims for the chip family, the
app's inferences with their reasoning, and the versions of the data files that annotated it. It
contains no serial number, UDID, identifierForVendor, hostname, boot time, account, or location.
It does contain the device model, OS build, kernel version string, and the time of collection.

## Conflicts

Two results for the same `identity` and `os_build` that disagree on a measured fact are shown as a
conflict in the matrix, never silently resolved. That includes `unrecognized_keys`: a key one
submission's walk found and another's did not, or whose value differs, is a conflict too. Usually
this means a bug in the app, an environment flag that slipped through, or something genuinely
interesting. Different `os_build`s for the same device are not conflicts; they are the OS-version
boundary the app exists to detect.

## How the matrix reads a result

- A `FEAT_*` column whose key the kernel does not register falls back to the legacy `armv8_*` alias
  the app's inventory maps to it, marked ᴬ in the cell.
- The documented table shows, per device, the result annotated with the newest documentation data
  and says how many results and distinct data snapshots it stands for. Apple's claims come from the
  app's bundled data at export time, so a newer export can carry revised claims.

## Running the tooling locally

```bash
cd Tools/generate-matrix && npm ci && npm run check      # validate everything under results/
cd Tools/generate-matrix && npm run generate              # also rewrite MATRIX.md and site/
```
