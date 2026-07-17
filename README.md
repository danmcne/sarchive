# sarchive.sh — safe archiving with version retention

`sarchive.sh` supersedes `sbackup.sh`.

`sarchive.sh` pushes files from a computer with limited disk space to an
archive on an external drive or remote machine, using `rsync`. The archive
accumulates: it holds the most recent version of everything ever pushed, plus
every version that was ever superseded. Nothing in the archive is ever
destroyed by the tool.

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
this script** — it would delete exactly the files whose local deletion was
the reason you archived them.

Everything in the archive is an ordinary file. Restoring anything, browsing
the history, or reading the archive twenty years from now requires no
software beyond a file manager or `cp`.

## Requirements

- `rsync` ≥ 3.2.3 (for `--mkpath`)
- `bash` ≥ 4.4
- GNU coreutils (`sort`, `shuf`) — standard on Linux
- `ssh`, for remote archives (optional)

## Initialising an archive root

Before the first push, mark the archive root, once per archive:

```
sarchive.sh -I /media/$USER/SSD/bob
```

This writes a small `.sarchive` marker file (a few bytes, never grows, never
rewritten) into the directory. The directory must already exist; `-I`
creates nothing and transfers nothing. Marking is deliberately a separate
command with a different shape — one path, no other flags — so it cannot be
habitually pasted into a normal push.

The marker gives the root an identity. Every subsequent run refuses to
proceed unless its destination lies at or below a marked root, which is what
catches the three ways an archive silently goes wrong:

- **the drive isn't mounted** — an unmounted mountpoint is an existing empty
  directory, indistinguishable from your archive by name, but it has no
  marker anywhere in its ancestry, so the run refuses instead of quietly
  filling your local disk;
- **a typo'd destination** — no marker, refused;
- **the wrong directory** — no marker, refused.

The root can be anywhere. If a drive holds several people's archives, mark
each person's directory, not the drive: marking `SSD/bob` leaves `SSD/alice`
entirely alone (and she may mark hers, or not, independently). If nested
markers ever exist, the nearest one above the destination governs.

One honest gap: if you run `-I` while the drive is unmounted, you mark the
mountpoint itself and the guard is defeated for that path. The marker turns
a hazard carried by every routine push into one requiring a deliberate,
unusual act — it does not make the hazard impossible.

## Usage

```
sarchive.sh -I <archive_root>
sarchive.sh [-v] [-c] [-n] [-s|-b] [-e PATTERN]... <source_dir> <dest_dir>
```

| Flag | Effect |
|------|--------|
| `-I` | Initialise an archive root. One path, no other flags. |
| `-v` | Verbose: per-file output and progress. |
| `-c` | Compare by checksum instead of size+mtime. See below. |
| `-n` | Dry run: report what would happen, change nothing. |
| `-s` | Shuffle: process top-level directories in random order. |
| `-b` | Bookmark: process top-level directories round-robin, resuming after the last completed directory of the previous `-b` run. |
| `-e P`| Exclude pattern, repeatable. `-e .cache/` excludes `.cache` at any depth; `-e /Downloads/` excludes only the top-level `Downloads`. Patterns anchor to the source root and mean the same thing in every mode. |
| `-h` | Help. |

The destination may be local or remote (`user@host:/path`); local and remote
take the same code path throughout. The archive root must exist (and be
marked); directories *below* the root are created as needed.

### Examples

```
sarchive.sh -I /media/$USER/SSD/bob             # once, ever
sarchive.sh -v ~ /media/$USER/SSD/bob/home      # whole home, when there's time
sarchive.sh -v ~/Pictures /media/$USER/SSD/bob/home/Pictures   # ten minutes
sarchive.sh -b ~ user@nas:/archive/bob/home     # round-robin, remote
sarchive.sh -c -n ~ /media/$USER/SSD/bob/home   # audit (see below)
```

## The path convention (load-bearing)

Map sources to consistent root-relative destinations: `~` always to
`bob/home`, and therefore `~/Pictures` always to `bob/home/Pictures`. Under
this convention, a run on a subdirectory and a run on the whole home are
**partial updates of the same tree** — files already archived compare equal
and are skipped in milliseconds, so the runs compose and nothing is stored
twice.

The tool cannot enforce this convention; only you can. Archiving
`~/Pictures` to `bob/home/Pictures` one month and to `bob/pics` the next
creates two unrelated copies, and nothing will warn you.

There is no saved position and no "resume state". A run always walks the
whole source and compares each file against the archive; "picking up where
it left off" is emergent — already-archived material costs a fast stat
comparison and nothing more. Interrupt any run at any moment: the only cost
is the re-comparison next time. A file interrupted mid-transfer resumes from
its partial data (over a network) and partial data is quarantined in a
hidden `.rsync-partial` directory — a truncated file never appears at a real
archive path.

## Archive layout

```
/media/$USER/SSD/bob/                    <- archive root
├── .sarchive                          <- marker (from -I)
├── home/                              <- your convention: ~ maps here
│   ├── .bashrc
│   ├── Pictures/
│   │   └── img.jpg                    <- current version
│   └── Work/
│       └── notes.txt
└── older_versions/
    ├── 2026-07-16T142305/             <- one run that superseded things
    │   └── home/Pictures/img.jpg      <- the version that run replaced
    └── 2026-07-17T091412/
        └── home/Work/notes.txt
```

Points worth noticing:

- The store is anchored at the **root**, not at each run's destination.
  Whether a version of `img.jpg` was superseded by a run on `~` or a run on
  `~/Pictures`, it lands at the same root-relative address. The full history
  of one file is `ls older_versions/*/home/Pictures/img.jpg`.
- Run directories are created lazily: a run that supersedes nothing leaves
  no directory.
- Filenames are unmangled. Restoring an old version is `cp`.
- `du -sh older_versions/*` prices every run; `ls older_versions/<run>/`
  answers "what did that push replace?"

## Ordering: default, `-s`, `-b`

By default a run is a single `rsync` invocation processing the source in
one pass. This is the right mode when runs usually finish.

If your runs are usually *interrupted* — you archive when you have time and
stop when you don't — a fixed processing order starves the tail: directories
that churn constantly (a `Downloads/` is both alphabetically early and churn 
frequently) absorb each run's time budget, and later directories are rarely
reached. Two remedies, both of which split the run into one transfer per
top-level directory:

- **`-s` (shuffle)** randomises the order each run. Stateless; fairness is
  statistical — no directory can starve because none has a position.
- **`-b` (bookmark)** rotates deterministically. A cursor file at the run's
  destination (`.sarchive-cursor`, one line, overwritten) records the last
  *completed* top-level directory; the next `-b` run processes the full list
  rotated to start just past it, wrapping around. Interrupted and completed
  runs are the same case: the cycle simply continues across runs.

The two are mutually exclusive. In all three modes the *result of a
completed run is identical* — ordering changes only which prefix survives an
interruption.

Properties of the cursor worth knowing:

- It is **advisory**: it influences order, never coverage. Every `-b` run
  still dispatches every top-level directory; skipping remains rsync's
  comparison, exactly as in the other modes. A stale, corrupt, or deleted
  cursor degrades to a suboptimal starting point — nothing can be missed.
  It is always safe to delete.
- It is per destination: archiving `~` to two drives are two independent
  rotations.
- The bookmark is a sort pivot, not a lookup: it still works if the
  directory it names has since been renamed or deleted.
- Rotation order is byte-order (`LC_ALL=C`) sorted, so capitalised names
  come before lowercase ones (`Work` before `bin`). This is deliberate:
  the order must be identical across runs and machines.
- Dry runs (`-n`) rotate from the cursor but never write it.
- Fairness in `-s`/`-b` is top-level only. If the churn is inside one giant
  directory, target that subtree directly — the root-anchored store makes
  such runs free.

## `-c`: change detection, not verification

By default rsync considers a file unchanged when size and mtime both match.
`-c` computes checksums for files whose sizes match, catching the narrow
case where content changed but size and mtime did not (restores, `cp -p`,
`tar -x`, coarse filesystem timestamps). The cost is a full read of both
trees; that is why it is a flag and not the default.

`-c` is *not* transfer verification — none is needed. rsync itself
checksums every transferred file end-to-end (sender and receiver compare a
whole-file hash; a mismatch triggers a retry and then a hard error, exit
code 23, which this script propagates as a failure). What rsync verifies is
the transfer, not the medium: it does not re-read the destination disk after
writing. For that, see the audit below.

## Auditing the archive

```
sarchive.sh -c -n <source> <dest>
```

`-c` forces a full read of the archived copies from disk; `-n` guarantees
nothing changes. Anything reported as needing transfer is a file whose
archived copy no longer matches the source — this catches silent corruption
(bitrot, a failing drive) that no mtime-based comparison can see. Add `-v`
to list the differing files.

The inherent limit: the audit compares against the source, so it can only
audit files still *present* on the source — precisely not the ones you
offloaded and deleted, which are the reason the archive exists. Verifying
those would require checksums recorded at push time (a manifest), which is a
real feature with real costs and failure modes of its own, and is
deliberately out of scope. Know the limit; don't mistake the audit for more
than it is.

## Pruning

The store grows forever by design; when you eventually want space back,
run directories make pruning a filesystem operation, not a tool feature:

```
rm -rf /media/$USER/SSD/bob/older_versions/2024-*
```

removes every superseded version from 2024 while touching nothing current.

## Notes, edges, and limits

- **Moved files.** The tool addresses files by path. Move a file locally
  and the archive gains a copy at the new path while keeping the old one —
  by design, since deletions never propagate. Duplicates on the archive are
  found and adjudicated with a separate tool (e.g. `dupfind`), by hand.
  Content-addressed tools (restic, borg) dissolve this entirely, at the
  price of an opaque repository that requires their software to read;
  this tool's premise is that plain browsable files are worth that price.
- **Remote costs.** Marker discovery costs one ssh round trip per ancestor
  level tried; `-s`/`-b` open one connection per top-level directory; `-b`
  adds one per completed directory for the cursor write. All of it collapses
  to near-zero with ssh connection multiplexing (`ControlMaster`) in your
  ssh config; the script will not manage your ssh config for you.
- **Vanished files.** Files disappearing from the source mid-run (normal on
  a live home directory) produce a warning, not a failure. Any other rsync
  error aborts the run and propagates rsync's exit code.
- **`-a` fidelity.** Ownership, permissions, times, symlinks and (via
  `--hard-links`) hard-link structure are preserved. ACLs and extended
  attributes are not; they fail unpredictably on foreign filesystems and are
  out of scope.
- **Symlinked directories** at the source's top level are archived as
  symlinks in every mode (never followed).
- **Archiving an archive.** If the source itself contains `.sarchive` or
  `.sarchive-cursor` at its top level, they will overwrite the
  destination's. Harmless but confusing; avoid.
- **Local paths** are best given absolute (or home-relative); marker
  discovery for a relative destination stops at its first component.
- **Migrating from the old sbackup layout.** Files versioned by the old
  suffix scheme (`name~YYYY-MM-DD-uuid`) coexist with run directories
  without collision. To keep one layout per directory, a one-time manual
  move suffices: `mkdir older_versions/pre-2026 && mv older_versions/*~* older_versions/pre-2026/`
  (adjust the glob to your actual names). No migration code exists or is
  needed.

## License

MIT.
