#!/bin/bash
#
# sarchive.sh — safe archive: accumulate-only, versioned pushes via rsync
#
# THE INVARIANT
#   The destination is an ARCHIVE, not a mirror. It only ever grows.
#
#     <root>/...                          the most recently pushed version of
#                                         every file ever pushed
#     <root>/older_versions/<run>/<path>  every version superseded by run <run>,
#                                         at its path relative to the root
#
#   Removing a file from the source does NOT remove it from the archive;
#   that is the point of the tool.  NEVER add --delete to this script:
#   it would delete precisely the files whose local deletion was the
#   reason the archive exists.
#
# STATE
#   <root>/.sarchive          marker: this directory is an archive root.
#                             Written once by -I, only ever tested for
#                             existence afterwards.  Never grows.
#   <dest>/.sarchive-cursor   advisory cursor for -b (round-robin ordering).
#                             Affects dispatch ORDER only, never coverage:
#                             no value it can hold causes anything to be
#                             missed.  Safe to delete at any time.

set -Eeuo pipefail
export LC_ALL=C   # deterministic sort order and string comparison throughout

MARKER=".sarchive"
CURSOR=".sarchive-cursor"
STORE="older_versions"
PARTIAL=".rsync-partial"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

usage() {
    cat >&2 <<EOF
Usage:
  sarchive.sh -I <archive_root>
  sarchive.sh [-v] [-c] [-n] [-s|-b] [-e PATTERN]... <source_dir> <dest_dir>
  sarchive.sh -h

  -I            initialise <archive_root> as an archive root (writes the
                .sarchive marker).  Takes exactly one path, no other flags,
                transfers nothing.  The directory must already exist.
  -v            verbose: per-file output and progress
  -c            compare by checksum instead of size+mtime (catches files
                whose content changed but whose size and mtime did not)
  -n            dry run: report what would happen, change nothing
  -s            shuffle: dispatch top-level directories in random order
  -b            bookmark: dispatch top-level directories round-robin,
                resuming after the last completed directory of the
                previous -b run (cursor stored at <dest>/.sarchive-cursor)
  -e PATTERN    exclude PATTERN (repeatable).  Patterns anchor to the
                source root in every mode: -e /Downloads/ excludes the
                top-level Downloads; -e .cache/ excludes .cache anywhere.
  -h            this help

<dest_dir> may be local or remote (user@host:/path).  It must lie at or
below an initialised archive root; the root is discovered by searching
the destination and its ancestors for the .sarchive marker.
EOF
    exit "${1:-1}"
}

die() { echo "sarchive: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# All destination-side probes and writes go through rsync itself, so local
# and remote destinations take literally the same code path: rsync resolves
# 'user@host:/path' and we never parse it.
# ---------------------------------------------------------------------------

marker_present() {  # $1 = candidate root (local path or user@host:/path)
    rsync --list-only "$1/$MARKER" >/dev/null 2>&1
}

# Walk upward from the destination looking for the marker.  dirname works
# unchanged on remote specs: dirname 'user@host:/a/b' -> 'user@host:/a'.
# Sets ROOT (marked ancestor), RELPATH (destination relative to ROOT, ""
# if the destination is the root itself).
find_root() {
    local cand="$1" rel="" parent
    while :; do
        if marker_present "$cand"; then
            ROOT="$cand"
            RELPATH="$rel"
            return 0
        fi
        parent="$(dirname "$cand")"
        [[ "$parent" == "$cand" || "$parent" == "." ]] && return 1
        rel="$(basename "$cand")${rel:+/$rel}"
        cand="$parent"
    done
}

ups() {  # print "../" repeated $1 times
    local n=$1 s=""
    while (( n-- > 0 )); do s+="../"; done
    printf '%s' "$s"
}

# Escape rsync wildcard characters in a literal name used inside a filter.
pat_escape() {
    printf '%s' "$1" | sed -e 's/[][*?\\]/\\&/g'
}

WARN_VANISHED=0
run_rsync() {
    local status=0
    rsync "$@" || status=$?
    case "$status" in
        0)  ;;
        24) WARN_VANISHED=1 ;;   # source files vanished mid-run: routine on
                                 # a live home directory; warn, don't fail
        *)  echo "sarchive: rsync failed with status $status" >&2
            exit "$status" ;;
    esac
}

# ---------------------------------------------------------------------------
# Cursor (advisory, -b only).  Read and written via rsync, same as the
# marker.  A write failure degrades ordering, not correctness, so it warns
# instead of failing.
# ---------------------------------------------------------------------------

read_cursor() {  # prints bookmark name, or nothing
    if rsync "$DEST/$CURSOR" "$TMP/cursor.in" >/dev/null 2>&1; then
        head -n1 "$TMP/cursor.in" | cut -f1
    fi
}

write_cursor() {  # $1 = completed directory name
    printf '%s\t%s\n' "$1" "$(date +%Y-%m-%dT%H%M%S)" > "$TMP/cursor.out"
    rsync "$TMP/cursor.out" "$DEST/$CURSOR" >/dev/null 2>&1 \
        || echo "sarchive: warning: could not update cursor at $DEST/$CURSOR" >&2
}

# ---------------------------------------------------------------------------
# -I: initialise an archive root.  Deliberately a separate mode with a
# different argument shape, so it cannot be habitually pasted into a normal
# push command.  Never creates the directory: marking a place is a statement
# about a place that exists.
# ---------------------------------------------------------------------------

do_init() {
    local target="${1%/}"
    [[ -n "$target" ]] || target="/"
    if marker_present "$target"; then
        echo "sarchive: $target is already an archive root."
        exit 0
    fi
    printf 'sarchive\nlayout=run-dirs\ncreated=%s\n' \
        "$(date +%Y-%m-%dT%H%M%S)" > "$TMP/$MARKER"
    local status=0
    rsync "$TMP/$MARKER" "$target/$MARKER" || status=$?
    if (( status != 0 )); then
        die "could not initialise $target (does the directory exist?)"
    fi
    echo "sarchive: initialised archive root at $target"
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

INIT=false VERBOSE=false CHECKSUM=false DRYRUN=false SHUFFLE=false BOOKMARK=false
EXCLUDES=()

while getopts ":Ivcnsbe:h" opt; do
    case "$opt" in
        I) INIT=true ;;
        v) VERBOSE=true ;;
        c) CHECKSUM=true ;;
        n) DRYRUN=true ;;
        s) SHUFFLE=true ;;
        b) BOOKMARK=true ;;
        e) EXCLUDES+=("$OPTARG") ;;
        h) usage 0 ;;
        *) usage ;;
    esac
done
shift $(( OPTIND - 1 ))

if $INIT; then
    if $VERBOSE || $CHECKSUM || $DRYRUN || $SHUFFLE || $BOOKMARK \
       || (( ${#EXCLUDES[@]} > 0 )) || (( $# != 1 )); then
        die "-I takes exactly one path and no other flags"
    fi
    do_init "$1"
fi

$SHUFFLE && $BOOKMARK && die "-s and -b are mutually exclusive: choose one ordering"
(( $# == 2 )) || usage

SOURCE="${1%/}"; [[ -n "$SOURCE" ]] || SOURCE="/"
DEST="${2%/}";   [[ -n "$DEST"   ]] || DEST="/"

[[ -d "$SOURCE" ]] || die "no such source directory: $SOURCE"

# ---------------------------------------------------------------------------
# Guard: the destination must lie under an initialised archive root.
# This is what catches the unmounted drive, the typo'd path, and the
# wrong directory — an unmounted mountpoint has no marker in its ancestry.
# ---------------------------------------------------------------------------

if ! find_root "$DEST"; then
    cat >&2 <<EOF
sarchive: $DEST is not inside an archive root (no $MARKER marker found
  in it or any parent directory).
  If your archive drive should be mounted there, it is probably NOT mounted.
  If this is a new archive:  sarchive.sh -I <archive_root>
EOF
    exit 1
fi

RUN_ID="$(date +%Y-%m-%dT%H%M%S)"

if [[ -z "$RELPATH" ]]; then
    DEPTH=0
else
    IFS=/ read -r -a _parts <<< "$RELPATH"
    DEPTH=${#_parts[@]}
fi

# The version store is anchored at the ROOT, not at this run's destination,
# so every run against this drive — whatever subtree it targets — deposits
# superseded files into one store, at their root-relative paths.  The path
# is given to rsync RELATIVE to the destination, so it needs no host prefix
# and is identical for local and remote roots.
BACKUP_DIR="$(ups "$DEPTH")$STORE/$RUN_ID${RELPATH:+/$RELPATH}"

opts=(
    --archive         # -rlptgoD: recurse, preserve links/perms/times/owners
    --hard-links      # -a does not preserve hard links; an archive should
    --compress        # pays over a network; bounded locally by skip-compress
    --mkpath          # create destination components BELOW the (proven) root
    --partial-dir="$PARTIAL"   # interrupted transfers resume; partial data
                               # is quarantined, never left at the real path
    --backup
)

if $VERBOSE;  then opts+=( --verbose --progress ); fi
if $CHECKSUM; then opts+=( --checksum ); fi
if $DRYRUN;   then opts+=( --dry-run ); fi

# User excludes come before any slice filters below: first match wins, so
# an exclude means the same thing in every mode.
if (( ${#EXCLUDES[@]} > 0 )); then
    for pattern in "${EXCLUDES[@]}"; do
        opts+=( --exclude="$pattern" )
    done
fi

echo "sarchive run $RUN_ID: $SOURCE -> $DEST  (archive root: $ROOT)"
$DRYRUN && echo "sarchive: DRY RUN — nothing will be changed"

# ---------------------------------------------------------------------------
# Dispatch.
#
# Default: one rsync call over the whole source.
#
# -s / -b: the transfer is split into one call for the source's top-level
# files plus one call per top-level directory, so the directory order can
# be shuffled (-s) or rotated round-robin from the cursor (-b).  Each call
# still runs over SOURCE/ -> DEST/ and selects its slice with filters, so
# exclude semantics, the backup dir, and the result are identical to the
# default mode.  A completed run's result is independent of order; ordering
# changes only which prefix survives an interruption.
# ---------------------------------------------------------------------------

if ! $SHUFFLE && ! $BOOKMARK; then
    run_rsync "${opts[@]}" --backup-dir="$BACKUP_DIR" "$SOURCE/" "$DEST/"
else
    # Enumerate top-level directories (including hidden; excluding symlinks,
    # which are archived as symlinks by the top-level-files call, exactly as
    # -a would in the default mode).
    names=()
    shopt -s dotglob nullglob
    for d in "$SOURCE"/*/; do
        d="${d%/}"
        [[ -L "$d" ]] && continue
        names+=( "$(basename "$d")" )
    done
    shopt -u dotglob nullglob

    if (( ${#names[@]} > 0 )); then
        mapfile -d '' -t names < <(printf '%s\0' "${names[@]}" | sort -z)
    fi

    if $SHUFFLE && (( ${#names[@]} > 0 )); then
        mapfile -d '' -t names < <(printf '%s\0' "${names[@]}" | shuf -z)
    elif $BOOKMARK && (( ${#names[@]} > 0 )); then
        bm="$(read_cursor)"
        if [[ -n "$bm" ]]; then
            echo "sarchive: cursor found; resuming after '$bm'"
            # Rotate: everything sorting after the bookmark first, then
            # wrap around.  The bookmark is a sort PIVOT, not a lookup —
            # it need not name an existing directory, and no value it can
            # hold shrinks coverage.
            after=(); before=()
            for d in "${names[@]}"; do
                if [[ "$d" > "$bm" ]]; then after+=( "$d" ); else before+=( "$d" ); fi
            done
            names=( ${after[@]+"${after[@]}"} ${before[@]+"${before[@]}"} )
        fi
    fi

    # Top-level files (dotfiles included) first: small, and they belong to
    # every run.
    echo "sarchive: [0/${#names[@]}] top-level files"
    run_rsync "${opts[@]}" --backup-dir="$BACKUP_DIR" \
        --exclude='/*/' "$SOURCE/" "$DEST/"

    i=0
    for name in ${names[@]+"${names[@]}"}; do
        i=$(( i + 1 ))
        echo "sarchive: [$i/${#names[@]}] $name"
        esc="$(pat_escape "$name")"
        run_rsync "${opts[@]}" --backup-dir="$BACKUP_DIR" \
            --include="/$esc/***" --exclude='/*' "$SOURCE/" "$DEST/"
        if $BOOKMARK && ! $DRYRUN; then
            write_cursor "$name"
        fi
    done
fi

if (( WARN_VANISHED )); then
    echo "sarchive run $RUN_ID: complete; some source files vanished during transfer" >&2
else
    echo "sarchive run $RUN_ID: complete"
fi
