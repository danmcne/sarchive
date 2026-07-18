# sarchive.sh — safe archiving with version retention

`sarchive.sh` pushes files from a computer with limited disk space to an
archive on an external drive or remote machine, using `rsync`. The archive
accumulates: it holds the most recent version of everything ever pushed, plus
every version that was ever superseded. Nothing in the archive is ever
destroyed by the tool, and no configuration can change that.

## The invariant

**The archive is not a mirror. It only ever grows.**

- `<root>/…` holds the most recently pushed version of every file ever
  pushed, as plain browsable files at their original paths.
- `<root>/older_versions/<run>/…` holds every file version superseded during
  run `<run>`, at its path relative to the archive root, under its original
  name.

Deleting a file from the source does **not** delete it from the archive.
That is the purpose of the tool: you free local disk space precisely because
the archive keeps the file. For the same reason, **never add `--delete` to
this script**, and there is deliberately no config directive that deletes —
a policy file must not be able to repeal the tool's one promise.

Everything in the archive is an ordinary file. Restoring anything, browsing
the history, or reading the archive twenty years from now requires no
software beyond a file manager or `cp`.

## Requirements

- `rsync` ≥ 3.2.3 (for `--mkpath`)
- `bash` ≥ 4.4, GNU coreutils — standard on Linux
- `ssh`, for remote archives (optional)

## Quick start

```
sarchive.sh -I /media/$USER/SSD/Dan        # once per archive, ever
$EDITOR ~/.sarchive.conf                   # standing policy (see below)
sarchive.sh ~ /media/$USER/SSD/Dan/home    # routine push: no flags needed
```

## Initialising an archive root

`-I` writes a small `.sarchive` marker (a few bytes, never rewritten) into
the directory you name. The directory must already exist; `-I` creates
nothing and transfers nothing, and it is deliberately a separate command
with a different shape — one path, no other flags — so it cannot be
habitually pasted into a normal push.

Every run then refuses to proceed unless its destination lies at or below a
marked root. This is what catches the three ways an archive silently goes
wrong: **the drive isn't mounted** (an unmounted mountpoint is an existing
empty directory with no marker in its ancestry, so the run refuses instead
of quietly filling your local disk), **a typo'd destination**, and **the
wrong directory**.

The root can be anywhere. On a shared drive, mark each person's directory,
not the drive: marking `SSD/Dan` leaves `SSD/Mary` alone. If nested markers
ever exist, the nearest one above the destination governs.

One honest gap: running `-I` while the drive is unmounted marks the
mountpoint itself, defeating the guard for that path. The marker turns a
hazard carried by every routine push into one requiring a single deliberate,
unusual act; it does not make the hazard impossible.

## The config file: `.sarchive.conf`

Standing policy lives in a plain file at the source root (typically
`~/.sarchive.conf`), discovered like a `.git` directory by walking up from
the source. It is ordinary visible data in your tree — not hidden tool
state — and it is archived along with everything else, so the archive
records its own policy. One directive per line, `#` comments:

```
# ~/.sarchive.conf
order bookmark          # default dispatch order: sorted | shuffle | bookmark
verbose off             # default verbosity

ignore .cache/          # rsync pattern: matches at any depth
ignore .venv/
ignore .global-venv/
ignore .elan/
ignore node_modules/
ignore /snap/           # leading / anchors to the source top level only

noversion .config       # kept current in the archive, but superseded
noversion .local        # versions are NOT saved to older_versions
```

The three verbs, in decreasing strength:

- **`ignore PATTERN`** — not archived at all. This is where regenerable
  material belongs: virtualenvs, toolchains, caches, `node_modules`. Archive
  the manifest that recreates them (`requirements.txt`), not the artifact.
  (`.local` sometimes holds real application data — game saves, app
  databases — so look before blanket-ignoring it.)
- **`noversion NAME`** — the top-level entry `NAME` is archived and kept
  current, but old versions are not retained. For trees like `.config`
  whose files churn constantly (recently-used lists, window geometry) and
  whose history is noise: you get a restorable settings snapshot without
  polluting `older_versions` with junk versions on every run.
- *(unlisted)* — archived with full version retention. This is the default
  on purpose: a new directory appearing in your home is archived until you
  say otherwise, never silently skipped.

An unknown directive is a fatal error with a file:line message, not a guess.
There is no `mirror`, no `delete`, and there never will be: a directive that
erases archive content on the say-so of a config line written months ago is
the exact failure this tool exists to prevent. If you ever need a true
mirror of something, plain `rsync -a --delete` to a *non-archive* path
already exists; it does not belong under the marker.

Targeted runs obey the standing policy: `sarchive.sh ~/.config …` runs in
noversion mode because the config says so; `sarchive.sh ~/.cache …` is
refused outright, with a message naming the config line to change if you
meant it.

`-e PATTERN` remains for one-off exclusions on a single run.

## Usage

```
sarchive.sh -I <archive_root>
sarchive.sh [-v] [-c] [-n] [-s|-b] [-e PATTERN]... <source_dir> <dest_dir>
```

| Flag | Effect |
|------|--------|
| `-I` | Initialise an archive root. One path, no other flags. |
| `-v` | Verbose (or set `verbose on` in the config). |
| `-c` | Compare by checksum instead of size+mtime. See below. |
| `-n` | Dry run: report what would happen, change nothing. |
| `-s` / `-b` | Shuffle / bookmark order for this run, overriding the config. |
| `-e P` | One-off exclude, repeatable. |
| `-h` | Help. |

With standing policy in the config, the routine invocation is just
`sarchive.sh <source> <dest>`. The destination may be local or remote
(`user@host:/path`); both take the same code path. The archive root must
exist and be marked; directories below it are created as needed.

## The path convention (load-bearing)

Map sources to consistent root-relative destinations: `~` always to
`Dan/home`, and therefore `~/Pictures` always to `Dan/home/Pictures`. Under
this convention a run on a subdirectory and a run on the whole home are
**partial updates of the same tree** — files already archived compare equal
and are skipped in milliseconds, so runs compose and nothing is stored
twice. The tool cannot enforce the convention; only you can.

There is no saved position and no resume state. A run always walks the
whole source and compares each file against the archive; "picking up where
it left off" is emergent — already-archived material costs a fast comparison
and nothing more. Interrupt any run at any moment; a file interrupted
mid-transfer resumes from its partial data (over a network), and partial
data is quarantined in a hidden `.rsync-partial` directory, never left at a
real archive path.

## Archive layout

```
/media/dan/SSD/Dan/                    <- archive root
├── .sarchive                          <- marker (from -I)
├── home/
│   ├── .bashrc
│   ├── .sarchive.conf                 <- the policy, archived with the data
│   ├── .config/…                      <- current copy (noversion)
│   ├── Pictures/
│   │   └── img.jpg                    <- current version
│   └── Work/…
└── older_versions/
    ├── 2026-07-16T142305/
    │   └── home/Pictures/img.jpg      <- the version that run replaced
    └── 2026-07-17T091412/
        └── home/Work/notes.txt
```

- The store is anchored at the **root**: whether a version of `img.jpg` was
  superseded by a run on `~` or on `~/Pictures`, it lands at the same
  root-relative address. One file's full history is
  `ls older_versions/*/home/Pictures/img.jpg`.
- Run directories are created lazily; a run that supersedes nothing leaves
  no directory. Filenames are unmangled; restoring an old version is `cp`.
- `du -sh older_versions/*` prices every run; `ls older_versions/<run>/`
  answers "what did that push replace?"

## Ordering: sorted, shuffle, bookmark

With `order sorted` (and no `noversion` entries) a run is a single rsync
pass — right when runs usually finish. If runs are usually *interrupted*,
a fixed order starves the tail: churn-heavy, alphabetically early
directories absorb each run's time budget. Two remedies, both dispatching
one transfer per top-level directory:

- **shuffle** randomises the order each run. Stateless; no directory can
  starve because none has a position.
- **bookmark** rotates deterministically. A cursor file at the run's
  destination (`.sarchive-cursor`, one line, overwritten) records the last
  *completed* top-level directory; the next run processes the full list
  rotated to start just past it, wrapping around, so interrupted and
  completed runs alike continue one cycle.

In all modes the *result of a completed run is identical*; ordering changes
only which prefix survives an interruption. The cursor is **advisory**: it
influences order, never coverage — every run still dispatches every entry,
and a stale, corrupt, or deleted cursor degrades to a suboptimal starting
point. It is always safe to delete. It is per destination; the bookmark is
a sort pivot, not a lookup, so it survives the named directory being renamed
or deleted; rotation order is byte-order (`LC_ALL=C`), so capitalised names
sort before lowercase (`Work` before `bin`) — deliberate, for cross-run
determinism. Dry runs rotate from the cursor but never write it. Fairness
is top-level only: if the churn is inside one giant directory, target that
subtree directly.

## `-c`: change detection, not verification

By default rsync treats a file as unchanged when size and mtime both match.
`-c` checksums files whose sizes match, catching content changes that moved
neither size nor mtime (restores, `cp -p`, `tar -x`, coarse timestamps).
It reads both trees in full — hence a flag, not the default.

Transfer verification needs no flag: rsync checksums every transferred file
end-to-end and retries on mismatch. What it verifies is the transfer, not
the medium — it does not re-read the destination disk afterward. For that:

```
sarchive.sh -c -n <source> <dest>       # audit
```

forces a full read of the archived copies from disk while changing nothing;
anything reported as needing transfer is an archived copy that no longer
matches the source — silent corruption no mtime comparison can see. The
inherent limit: the audit compares against the source, so it cannot check
files you have already offloaded and deleted — precisely the archive's most
important contents. Verifying those would need checksums recorded at push
time (a manifest): a real feature with real costs, deliberately out of
scope. Know the limit.

## Pruning

The store grows forever by design. When you want space back, run
directories make pruning a filesystem operation, not a tool feature:

```
rm -rf /media/$USER/SSD/Dan/older_versions/2024-*
```

## Filesystem realities (exFAT and friends)

External drives shared with Windows are typically exFAT, which cannot
represent symlinks, Unix permissions and ownership, or hard links. The
tool's stance:

- **Symlinks, permissions, attributes** that the destination cannot store
  produce rsync per-file errors and exit code 23. This is reported as a
  **warning**, not a failure: the errors describe data the filesystem
  genuinely cannot hold, and everything representable was transferred.
- **Hard links are not preserved anywhere** (`--hard-links` is deliberately
  absent). On exFAT it makes rsync abort fatally mid-run; and hardlinked-ness
  is metadata that cannot survive the tool's own promise of plain files
  restorable to any filesystem. Hardlinked sets (e.g. `.elan/bin`) archive
  as independent copies: every byte present, link structure lost. If a
  hardlink-heavy tree is really just a reinstallable toolchain, `ignore`
  it and archive its manifest instead.

Files vanishing from the source mid-run (normal on a live home directory)
are likewise a warning (rsync code 24). Any other rsync error aborts the
run and propagates rsync's exit code.

## Notes, edges, and limits

- **Moved files.** The tool addresses files by path: move a file locally and
  the archive gains a copy at the new path while keeping the old — by
  design, since deletions never propagate. Duplicates on the archive are
  found and adjudicated with a separate tool (e.g. `dupfind`), by hand.
  Content-addressed tools (restic, borg) dissolve this at the price of an
  opaque repository; this tool's premise is that plain browsable files are
  worth that price.
- **Remote costs.** Marker discovery costs one ssh round trip per ancestor
  level; split dispatch opens one connection per top-level directory;
  bookmark adds one per completed entry. All near-zero with ssh
  `ControlMaster` multiplexing.
- **Symlinked directories** at the source top level are archived as symlinks
  in every mode, never followed.
- **Archiving an archive.** If the source itself contains `.sarchive` or
  `.sarchive-cursor` at its top level they will overwrite the destination's.
  Harmless but confusing; avoid.
- **Local paths** are best given absolute or home-relative; marker discovery
  for a relative destination stops at its first path component.
- **Migrating from the old sbackup layout.** Old suffix-versioned files
  (`name~YYYY-MM-DD-uuid`) coexist with run directories without collision.
  For one layout per directory:
  `mkdir older_versions/pre-2026 && mv older_versions/*~* older_versions/pre-2026/`
  (adjust the glob). No migration code exists or is needed.

## License

MIT.
