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
#   that is the point of the tool.  NEVER add --delete to this script,
#   and no config directive may enable deletion: it would delete precisely
#   the files whose local deletion was the reason the archive exists.
#
# POLICY (config file, discovered by walking up from the source)
#   .sarchive.conf, one directive per line:
#     order sorted|shuffle|bookmark    default dispatch order   (default sorted)
#     verbose on|off                   default verbosity        (default off)
#     ignore PATTERN                   exclude PATTERN (rsync pattern syntax;
#                                      "x/" matches at any depth, "/x/" only
#                                      at the source top level)
#     noversion NAME                   top-level entry NAME is kept current in
#                                      the archive but superseded versions are
#                                      NOT saved to older_versions
#   There is deliberately no directive that deletes anything.
#
# STATE
#   <root>/.sarchive          marker: this directory is an archive root.
#   <dest>/.sarchive-cursor   advisory cursor for bookmark ordering.  Affects
#                             dispatch ORDER only, never coverage.  Safe to
#                             delete at any time.
#
# FIDELITY
#   --hard-links is deliberately absent: on filesystems without hard links
#   (exFAT, FAT, many network mounts) it makes rsync abort fatally (code 13),
#   and the linked-ness of files is unrepresentable there anyway.  Hardlinked
#   sets archive as independent copies: every byte present, structure lost.

set -Eeuo pipefail
export LC_ALL=C   # deterministic sort order and string comparison throughout

MARKER=".sarchive"
CURSOR=".sarchive-cursor"
CONFNAME=".sarchive.conf"
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
                .sarchive marker).  One path, no other flags, transfers
                nothing.  The directory must already exist.
  -v            verbose (per-file output and progress)
  -c            compare by checksum instead of size+mtime
  -n            dry run: report what would happen, change nothing
  -s / -b       shuffle / bookmark dispatch order (overrides config 'order')
  -e PATTERN    extra exclude for this run (repeatable)
  -h            this help

Standing policy lives in $CONFNAME at the source root (see header comment);
routine runs then need no flags:  sarchive.sh <source> <dest>
EOF
    exit "${1:-1}"
}

die() { echo "sarchive: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Destination-side probes and writes go through rsync itself, so local and
# remote destinations take literally the same code path.
# ---------------------------------------------------------------------------

marker_present() { rsync --list-only "$1/$MARKER" >/dev/null 2>&1; }

find_root() {   # sets ROOT, RELPATH (dest relative to ROOT, "" if equal)
    local cand="$1" rel="" parent
    while :; do
        if marker_present "$cand"; then
            ROOT="$cand"; RELPATH="$rel"; return 0
        fi
        parent="$(dirname "$cand")"
        [[ "$parent" == "$cand" || "$parent" == "." ]] && return 1
        rel="$(basename "$cand")${rel:+/$rel}"
        cand="$parent"
    done
}

ups() { local n=$1 s=""; while (( n-- > 0 )); do s+="../"; done; printf '%s' "$s"; }

pat_escape() { printf '%s' "$1" | sed -e 's/[][*?\\]/\\&/g'; }

# ---------------------------------------------------------------------------
# rsync exit handling.  Nothing that leaves the archive intact is fatal:
#   23  partial transfer: some files/attrs could not be transferred.  Routine
#       on destinations that cannot represent symlinks, permissions, etc.
#       (exFAT).  Per-file details are in rsync's own output above.
#   24  source files vanished mid-run: routine on a live home directory.
# Everything else aborts and propagates rsync's code.
# ---------------------------------------------------------------------------

WARN_PARTIAL=0
WARN_VANISHED=0
run_rsync() {
    local status=0
    rsync "$@" || status=$?
    case "$status" in
        0)  ;;
        23) WARN_PARTIAL=1 ;;
        24) WARN_VANISHED=1 ;;
        *)  echo "sarchive: rsync failed with status $status" >&2
            exit "$status" ;;
    esac
}

# ---------------------------------------------------------------------------
# Cursor (advisory, bookmark order only).
# ---------------------------------------------------------------------------

read_cursor() {
    if rsync "$DEST/$CURSOR" "$TMP/cursor.in" >/dev/null 2>&1; then
        head -n1 "$TMP/cursor.in" | cut -f1
    fi
}

write_cursor() {
    printf '%s\t%s\n' "$1" "$(date +%Y-%m-%dT%H%M%S)" > "$TMP/cursor.out"
    rsync "$TMP/cursor.out" "$DEST/$CURSOR" >/dev/null 2>&1 \
        || echo "sarchive: warning: could not update cursor at $DEST/$CURSOR" >&2
}

# ---------------------------------------------------------------------------
# Config discovery and parsing.  The config lives in the source tree, is
# discovered like a .git directory (walk up from the source), and is archived
# along with everything else, so the archive records its own policy.
# Unknown directives are an error, not a guess.
# ---------------------------------------------------------------------------

CONF_DIR="" CONF_FILE="" CONF_ORDER="" CONF_VERBOSE=""
CONF_IGNORES=()
NOVERSION=()

find_config() {
    local cand parent
    cand="$(realpath "$1")"
    while :; do
        if [[ -f "$cand/$CONFNAME" ]]; then
            CONF_DIR="$cand"; CONF_FILE="$cand/$CONFNAME"; return 0
        fi
        parent="$(dirname "$cand")"
        [[ "$parent" == "$cand" ]] && return 1
        cand="$parent"
    done
}

parse_config() {
    local key val lineno=0
    while IFS=$' \t' read -r key val || [[ -n "$key" ]]; do
        lineno=$(( lineno + 1 ))
        [[ -z "$key" || "$key" == \#* ]] && continue
        case "$key" in
            order)
                case "$val" in
                    sorted|shuffle|bookmark) CONF_ORDER="$val" ;;
                    *) die "$CONF_FILE:$lineno: order must be sorted, shuffle, or bookmark" ;;
                esac ;;
            verbose)
                case "$val" in
                    on|off) CONF_VERBOSE="$val" ;;
                    *) die "$CONF_FILE:$lineno: verbose must be on or off" ;;
                esac ;;
            ignore)
                [[ -n "$val" ]] || die "$CONF_FILE:$lineno: ignore needs a pattern"
                CONF_IGNORES+=( "$val" ) ;;
            noversion)
                [[ -n "$val" ]] || die "$CONF_FILE:$lineno: noversion needs a name"
                [[ "$val" == */* ]] && die "$CONF_FILE:$lineno: noversion takes a top-level entry name, not a path"
                NOVERSION+=( "${val%/}" ) ;;
            *)  die "$CONF_FILE:$lineno: unknown directive '$key' (known: order, verbose, ignore, noversion)" ;;
        esac
    done < "$CONF_FILE"
}

is_noversion() {
    local n
    for n in ${NOVERSION[@]+"${NOVERSION[@]}"}; do
        [[ "$n" == "$1" ]] && return 0
    done
    return 1
}

# A top-level entry whose name exactly matches a simple ignore pattern
# ("name", "name/", "/name/") is not dispatched at all in split mode.
# General patterns still apply inside every transfer via --exclude.
name_ignored() {
    local p s
    for p in ${ALL_IGNORES[@]+"${ALL_IGNORES[@]}"}; do
        s="${p#/}"; s="${s%/}"
        [[ "$s" == "$1" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# -I: initialise an archive root.  A separate mode with a different argument
# shape so it cannot be habitually pasted into a normal push.  Never creates
# the directory.
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
    (( status == 0 )) || die "could not initialise $target (does the directory exist?)"
    echo "sarchive: initialised archive root at $target"
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

INIT=false FLAG_V=false CHECKSUM=false DRYRUN=false FLAG_S=false FLAG_B=false
EXCLUDES=()

while getopts ":Ivcnsbe:h" opt; do
    case "$opt" in
        I) INIT=true ;;
        v) FLAG_V=true ;;
        c) CHECKSUM=true ;;
        n) DRYRUN=true ;;
        s) FLAG_S=true ;;
        b) FLAG_B=true ;;
        e) EXCLUDES+=("$OPTARG") ;;
        h) usage 0 ;;
        *) usage ;;
    esac
done
shift $(( OPTIND - 1 ))

if $INIT; then
    if $FLAG_V || $CHECKSUM || $DRYRUN || $FLAG_S || $FLAG_B \
       || (( ${#EXCLUDES[@]} > 0 )) || (( $# != 1 )); then
        die "-I takes exactly one path and no other flags"
    fi
    do_init "$1"
fi

$FLAG_S && $FLAG_B && die "-s and -b are mutually exclusive: choose one ordering"
(( $# == 2 )) || usage

SOURCE="${1%/}"; [[ -n "$SOURCE" ]] || SOURCE="/"
DEST="${2%/}";   [[ -n "$DEST"   ]] || DEST="/"

[[ -d "$SOURCE" ]] || die "no such source directory: $SOURCE"

# ---------------------------------------------------------------------------
# Resolve policy: config, ordering, verbosity, excludes, run verb.
# ---------------------------------------------------------------------------

SRC_ABS="$(realpath "$SOURCE")"
if find_config "$SRC_ABS"; then
    parse_config
fi

ORDER="sorted"
[[ -n "$CONF_ORDER" ]] && ORDER="$CONF_ORDER"
$FLAG_S && ORDER="shuffle"
$FLAG_B && ORDER="bookmark"

VERBOSE=false
[[ "$CONF_VERBOSE" == "on" ]] && VERBOSE=true
$FLAG_V && VERBOSE=true

ALL_IGNORES=( ${EXCLUDES[@]+"${EXCLUDES[@]}"} ${CONF_IGNORES[@]+"${CONF_IGNORES[@]}"} )

# Which policy governs this run?  If the source IS the config directory,
# per-entry verbs apply during dispatch.  If the source lies inside one
# top-level entry of the config directory, that entry's verb governs the
# whole run — a targeted run obeys the same standing policy as a full one.
RUN_VERB="archive"      # archive | noversion
PER_ENTRY=false
GOV_ENTRY=""
if [[ -n "$CONF_DIR" ]]; then
    rel="$(realpath --relative-to="$CONF_DIR" "$SRC_ABS")"
    if [[ "$rel" == "." ]]; then
        PER_ENTRY=true
    elif [[ "$rel" != ..* ]]; then
        GOV_ENTRY="${rel%%/*}"
        if name_ignored "$GOV_ENTRY"; then
            die "policy in $CONF_FILE ignores '$GOV_ENTRY'; edit the config if you want it archived"
        fi
        is_noversion "$GOV_ENTRY" && RUN_VERB="noversion"
    fi
fi

# ---------------------------------------------------------------------------
# Guard: the destination must lie under an initialised archive root.  This
# catches the unmounted drive (an unmounted mountpoint has no marker in its
# ancestry), the typo'd path, and the wrong directory.
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

# The version store is anchored at the ROOT, so every run against this
# drive — whatever subtree it targets — deposits superseded files into one
# store at their root-relative paths.  Relative to the destination, so it
# needs no host prefix and is identical for local and remote roots.
BACKUP_DIR="$(ups "$DEPTH")$STORE/$RUN_ID${RELPATH:+/$RELPATH}"
BK=( --backup --backup-dir="$BACKUP_DIR" )

opts=(
    --archive                  # -rlptgoD; see header for why NOT --hard-links
    --compress                 # pays over a network; bounded locally
    --mkpath                   # create destination components BELOW the root
    --partial-dir="$PARTIAL"   # interrupted transfers resume; partial data is
                               # quarantined, never left at a real path
)
$VERBOSE  && opts+=( --verbose --progress )
$CHECKSUM && opts+=( --checksum )
$DRYRUN   && opts+=( --dry-run )

for pattern in ${ALL_IGNORES[@]+"${ALL_IGNORES[@]}"}; do
    opts+=( --exclude="$pattern" )
done

echo "sarchive run $RUN_ID: $SOURCE -> $DEST  (archive root: $ROOT)"
if [[ -n "$CONF_FILE" ]]; then
    echo "sarchive: policy: $CONF_FILE (${#CONF_IGNORES[@]} ignore, ${#NOVERSION[@]} noversion, order $ORDER)"
fi
[[ "$RUN_VERB" == "noversion" ]] && echo "sarchive: '$GOV_ENTRY' is noversion: superseded versions will not be kept"
$DRYRUN && echo "sarchive: DRY RUN — nothing will be changed"

# ---------------------------------------------------------------------------
# Dispatch.
#
# Single call when nothing requires per-entry treatment: sorted order and
# (at a config root) no noversion entries.  Otherwise split into one call
# for the source's top-level files plus one per top-level directory, each
# selecting its slice with filters over the same SOURCE/ -> DEST/ transfer,
# so exclude semantics and the result are identical in every mode.  A
# completed run's result is independent of order; ordering changes only
# which prefix survives an interruption.
# ---------------------------------------------------------------------------

need_split=false
[[ "$ORDER" != "sorted" ]] && need_split=true
$PER_ENTRY && (( ${#NOVERSION[@]} > 0 )) && need_split=true

if ! $need_split; then
    if [[ "$RUN_VERB" == "noversion" ]]; then
        run_rsync "${opts[@]}" "$SOURCE/" "$DEST/"
    else
        run_rsync "${opts[@]}" "${BK[@]}" "$SOURCE/" "$DEST/"
    fi
else
    # Enumerate top-level directories (hidden included; symlinks excluded —
    # they are archived as symlinks by the top-level-files call, exactly as
    # in a single-call run).  Entries matching a simple ignore pattern are
    # not dispatched at all.
    names=()
    shopt -s dotglob nullglob
    for d in "$SOURCE"/*/; do
        d="${d%/}"
        [[ -L "$d" ]] && continue
        n="$(basename "$d")"
        name_ignored "$n" && continue
        names+=( "$n" )
    done
    shopt -u dotglob nullglob

    if (( ${#names[@]} > 0 )); then
        mapfile -d '' -t names < <(printf '%s\0' "${names[@]}" | sort -z)
    fi

    if [[ "$ORDER" == "shuffle" ]] && (( ${#names[@]} > 0 )); then
        mapfile -d '' -t names < <(printf '%s\0' "${names[@]}" | shuf -z)
    elif [[ "$ORDER" == "bookmark" ]] && (( ${#names[@]} > 0 )); then
        bm="$(read_cursor)"
        if [[ -n "$bm" ]]; then
            echo "sarchive: cursor found; resuming after '$bm'"
            # The bookmark is a sort PIVOT, not a lookup: it still works if
            # the entry it names is gone, and no value it can hold shrinks
            # coverage — every entry is always dispatched.
            after=(); before=()
            for d in "${names[@]}"; do
                if [[ "$d" > "$bm" ]]; then after+=( "$d" ); else before+=( "$d" ); fi
            done
            names=( ${after[@]+"${after[@]}"} ${before[@]+"${before[@]}"} )
        fi
    fi

    # Top-level files (dotfiles included) first: small, part of every run,
    # always versioned.
    echo "sarchive: [0/${#names[@]}] top-level files"
    if [[ "$RUN_VERB" == "noversion" ]]; then
        run_rsync "${opts[@]}" --exclude='/*/' "$SOURCE/" "$DEST/"
    else
        run_rsync "${opts[@]}" "${BK[@]}" --exclude='/*/' "$SOURCE/" "$DEST/"
    fi

    i=0
    for name in ${names[@]+"${names[@]}"}; do
        i=$(( i + 1 ))
        verb="$RUN_VERB"
        $PER_ENTRY && { verb="archive"; is_noversion "$name" && verb="noversion"; }
        if [[ "$verb" == "noversion" ]]; then
            echo "sarchive: [$i/${#names[@]}] $name (noversion)"
        else
            echo "sarchive: [$i/${#names[@]}] $name"
        fi
        esc="$(pat_escape "$name")"
        if [[ "$verb" == "noversion" ]]; then
            run_rsync "${opts[@]}" --include="/$esc/***" --exclude='/*' "$SOURCE/" "$DEST/"
        else
            run_rsync "${opts[@]}" "${BK[@]}" --include="/$esc/***" --exclude='/*' "$SOURCE/" "$DEST/"
        fi
        if [[ "$ORDER" == "bookmark" ]] && ! $DRYRUN; then
            write_cursor "$name"
        fi
    done
fi

(( WARN_PARTIAL )) && echo "sarchive: warning: some files or attributes could not be transferred (details above; typical for symlinks/permissions on exFAT and similar filesystems)" >&2
(( WARN_VANISHED )) && echo "sarchive: warning: some source files vanished during the run" >&2
echo "sarchive run $RUN_ID: complete"
