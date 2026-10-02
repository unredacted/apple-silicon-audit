# Upstream watcher

The watcher notices when Apple changes something the app's data files depend on, and opens a
GitHub issue with the evidence. It never edits the data: a human reads the issue and opens a PR.
The design is in SPEC §15. The workflow is `.github/workflows/watch.yml`.

## What it watches

| detector | when | sources | issue |
|---|---|---|---|
| firmware | daily | AppleDB build indexes (betas included) and per-build sources; restore manifests (`BuildManifest.plist`) read by HTTP range request; AppleDB and ipsw.me device maps; the KDK mirror's macOS kernel targets | `gap/sptm`, `gap/soc-map` |
| docs | daily | the Platform Security "Operating system integrity" table, its Published Date and footnotes; the guide PDF's headers; the revision-history page; the Security Research blog feed | `gap/guide-table`, one issue per event |
| xnu | daily | the newest `apple-oss-distributions/xnu` tag: `arm_features.inc`, `cpu_capabilities_public.h`, `machine.h` | `gap/known-keys`, `gap/caps-bits`, `gap/cpufamily` |
| headers | Mondays | every installed Xcode's macOS and iOS SDK headers, on the `macos-26` and `xcode-27` runners | `gap/caps-bits`, `gap/cpufamily` |
| results | every run | `unrecognized_keys`, `soc_id` and `cpufamily` in `results/` | `gap/known-keys`, `gap/soc-map`, `gap/cpufamily` |
| kernelcache | when new builds are queued | a representative device's kernelcache per OS, decompressed by the pinned `ipsw`; `FEAT_*` strings and the Darwin banner | `gap/kernelcache` (heuristic), or evidence on `gap/known-keys` |

Problems with the watcher itself go to one `health/<detector>` issue per detector.

## Triage

- **A gap issue lists everything one data file is behind on.** Fix the data in a PR. When that PR
  merges, the push-triggered run closes the issue (or comments on what is left). Each issue says
  what to do, including traps such as the `CAP_BIT_NB` coupling with the tests and the caps decoder.
- **An event issue is one upstream change**: a revised guide PDF, a revision-history entry, a blog
  post. Read it and close it yourself.
- **A health issue** means a detector could not observe something: network failures (three in a
  row), a parse failure (Apple changed a page layout), a missing artifact, a runner without the
  required SDK. Earlier evidence is kept, and nothing was closed because of the failure. The item
  clears when the same producer or scope succeeds again.
- **Not acting on a finding:** add `"<fingerprint>#<item>": {"reason", "who", "date"}` to
  `config/ignore.json` in a PR. Closing a gap issue by hand also works: the bot reopens it only for
  items it has not shown before. Don't remove the `watch` label, or the bot opens a duplicate.

## Running it locally

Use Python 3.9 or later with the standard library only. Run from the repo root:

    python3 -m unittest discover -s Tools/upstream-watch/tests -t Tools/upstream-watch/tests
    S=$(mktemp -d)
    GITHUB_TOKEN=$(gh auth token) python3 Tools/upstream-watch/watch.py observe --producer observe --state-dir "$S/state" --out "$S/art"
    python3 Tools/upstream-watch/watch.py observe --producer headers@local --out "$S/art"    # this Mac's Xcodes
    python3 Tools/upstream-watch/watch.py merge --artifacts "$S/art" --state-dir "$S/state"
    python3 Tools/upstream-watch/watch.py reconcile --state-dir "$S/state" --bodies
    python3 Tools/upstream-watch/watch.py reconcile --state-dir "$S/state" --ignore-exceptions   # what the SPTM exceptions cover

The first observe into an empty state is a bootstrap: it tracks only the newest release and the
newest beta of each OS. Every later build is tracked as it appears.

## State and guarantees

`state/` is committed by the bot, one file per section. These guarantees are tested in
`tests/test_merge.py` and `tests/test_publish.py`:

- **Evidence merges scope by scope.** Manifest and kernelcache results are stored by (work id,
  source fingerprint). A failed, skipped or empty run changes no evidence.
- **Work is queued, never dropped.** At most 40 manifests and 4 kernelcaches run each day; the rest
  waits. Failures back off by date (1, 2, 4 and 8 days). A build whose AppleDB sources change,
  for example an encrypted-only OTA that later gains an IPSW, is re-queued. Re-fetches rotate over
  every tracked build without a stored cursor.
- **Every outcome is applied once.** `applied.json` keeps the application ids that changed state, so
  a retry after a lost push response never double-counts a failure.
- **No per-run metadata.** A clean run with unchanged upstream makes no commit and no issue API
  call. Issue bodies depend only on committed evidence.
- **Events are durable.** One is recorded as `pending` in the same commit as the snapshot that found
  it, and acknowledged only after its issue exists. The issue is found by fingerprint, so a lost
  response never duplicates it.

To re-baseline a section, delete its file in a PR.

## The `ipsw` pin

The kernelcache job downloads `ipsw` at the version and SHA-256 in `watch.yml` and uses it only to
decompress. It runs in a job without write permission. To bump it:

1. Pick a release that has been public for at least a week.
2. Verify `checksums.txt` against `checksums.txt.sig` with cosign, as described in the ipsw release
   notes.
3. Copy the Linux x86_64 tarball's hash into `IPSW_SHA256`.

## Keeping the schedule alive

GitHub disables scheduled workflows in a public repository after 60 days without activity. The
bot's state commits count as activity, and `heartbeat.json` changes every month, so even a quiet
month makes one commit.
