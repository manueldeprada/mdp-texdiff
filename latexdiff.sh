#!/usr/bin/env bash
# Build a latexdiff PDF between two states of a LaTeX source tree.
#
# Usage:
#   latexdiff.sh [--tex-dir PATH] [OLD_REF] [NEW_REF]
#
# Run from inside the target git repo (or any subdirectory of it); this
# script does not need to live inside that repo.
#
# OLD_REF defaults to HEAD, NEW_REF defaults to WORKING (the current
# working tree, including both staged and unstaged uncommitted changes).
# Either can be any git ref (commit, tag, branch) instead, or one of two
# pseudo-refs: WORKING (as above) and STAGED (the index: what "git diff
# --cached" would show against HEAD). Examples:
#
#   latexdiff.sh                       # HEAD vs. working tree (default)
#   latexdiff.sh HEAD~3                # HEAD~3 vs. working tree
#   latexdiff.sh v1 v2                 # two tagged commits/branches
#   latexdiff.sh HEAD STAGED           # last commit vs. staged changes
#   latexdiff.sh STAGED WORKING        # staged vs. unstaged changes
#   latexdiff.sh --tex-dir paper v1 v2 # explicit LaTeX source directory
#
# The directory holding main.tex is auto-detected by searching the repo
# for a tracked main.tex. If the repo has more than one (or the file
# isn't tracked yet), pass --tex-dir PATH (relative to the repo root) or
# set the TEX_DIR environment variable to disambiguate.
#
# Deleted \alice{}/\bob{}/... comments (any todonotes wrapper macro
# defined as \newcommand{\name}[2][]{\note[#1]{label}{color}{#2}} anywhere
# under the LaTeX source directory) render as gray struck-through todo
# bubbles instead of being silently dropped or dumped inline into the body
# text. The macro names are discovered from the tex sources at run time,
# so a new coauthor's note command needs no change to this script, and a
# repo with no such macros at all just gets a plain latexdiff build.
# See latexdiff_notes.py and README.md for why that needs a rewrite step
# instead of a plain latexdiff flag.
#
# TEXTCMD (optional env var, default "claudetext,codextext"): a
# comma-separated list of color/formatting wrapper macros whose text
# argument should get latexdiff's inline blue/red markup instead of the
# wrapper's own color silently winning. Harmless to leave at the default
# if your document doesn't define these macros.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TEX_DIR_OVERRIDE="${TEX_DIR:-}"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tex-dir)
      TEX_DIR_OVERRIDE="$2"
      shift 2
      ;;
    --tex-dir=*)
      TEX_DIR_OVERRIDE="${1#--tex-dir=}"
      shift
      ;;
    -h|--help)
      echo "Usage: latexdiff.sh [--tex-dir PATH] [OLD_REF] [NEW_REF]"
      echo "See the header comment of this script, or README.md, for details."
      exit 0
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
  set -- "${POSITIONAL[@]}"
else
  set --
fi

OLD_REF="${1:-HEAD}"
NEW_REF="${2:-WORKING}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILD_DIR="$SCRIPT_DIR/build"
mkdir -p "$BUILD_DIR"

if [[ -n "$TEX_DIR_OVERRIDE" ]]; then
  TEX_SUBDIR="${TEX_DIR_OVERRIDE%/}"
  if [[ ! -f "$REPO_ROOT/$TEX_SUBDIR/main.tex" ]]; then
    echo "error: no main.tex in $REPO_ROOT/$TEX_SUBDIR" >&2
    exit 1
  fi
else
  CANDIDATES=()
  while IFS= read -r line; do
    [[ -n "$line" && "$(basename "$line")" == "main.tex" ]] && CANDIDATES+=("$line")
  done < <(git -C "$REPO_ROOT" ls-files || true)
  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "error: no tracked main.tex found under $REPO_ROOT." >&2
    echo "Pass --tex-dir PATH (relative to the repo root) or set TEX_DIR." >&2
    exit 1
  elif [[ ${#CANDIDATES[@]} -gt 1 ]]; then
    echo "error: multiple main.tex files found:" >&2
    printf '  %s\n' "${CANDIDATES[@]}" >&2
    echo "Disambiguate with --tex-dir PATH (relative to the repo root) or TEX_DIR." >&2
    exit 1
  fi
  TEX_SUBDIR="$(dirname "${CANDIDATES[0]}")"
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

OLD_DIR="$WORKDIR/old"
NEW_DIR="$WORKDIR/new"
mkdir -p "$OLD_DIR" "$NEW_DIR"

RSYNC_EXCLUDES=(--exclude='*.pdf' --exclude='_minted*' --exclude='*.aux' \
  --exclude='*.log' --exclude='*.out' --exclude='*.bbl' --exclude='*.blg' \
  --exclude='*.fls' --exclude='*.fdb_latexmk' --exclude='*.synctex.gz')

# When main.tex sits at the repo root, TEX_SUBDIR is ".", and a "git
# archive ... -- ." tar entry has no directory prefix (just "main.tex",
# not "some/dir/main.tex"), so there is nothing for --strip-components=1
# to strip; using it anyway would eat the filename itself.
ARCHIVE_STRIP=1
[[ "$TEX_SUBDIR" == "." ]] && ARCHIVE_STRIP=0

populate() {
  local ref="$1" dest="$2"
  case "$ref" in
    WORKING)
      rsync -a "${RSYNC_EXCLUDES[@]}" "$REPO_ROOT/$TEX_SUBDIR/" "$dest/"
      ;;
    STAGED)
      # git write-tree snapshots the current index as a tree object. It
      # only writes to the object database (no ref, no commit, no change
      # to the index or working tree), so this is as read-only as the
      # WORKING/ref cases above.
      local tree
      tree="$(git -C "$REPO_ROOT" write-tree)"
      git -C "$REPO_ROOT" archive "$tree" -- "$TEX_SUBDIR" \
        | tar -x -C "$dest" --strip-components="$ARCHIVE_STRIP"
      ;;
    *)
      git -C "$REPO_ROOT" archive "$ref" -- "$TEX_SUBDIR" \
        | tar -x -C "$dest" --strip-components="$ARCHIVE_STRIP"
      ;;
  esac
}

populate "$OLD_REF" "$OLD_DIR"
populate "$NEW_REF" "$NEW_DIR"

# Discover todonotes wrapper macros from the NEW side, so any coauthor note
# command added later (\carol, \dave, ...) is picked up automatically
# without editing this script.
NAMES_FILE="$WORKDIR/note_names.txt"
MACROS_FILE="$WORKDIR/note_del_macros.tex"
python3 "$SCRIPT_DIR/latexdiff_notes.py" discover "$NEW_DIR" \
  --names-out "$NAMES_FILE" --macros-out "$MACROS_FILE"
CONTEXT1_NAMES="$(cat "$NAMES_FILE")"

TEXTCMD="${TEXTCMD:-claudetext,codextext}"
LATEXDIFF_ARGS=(--append-textcmd="$TEXTCMD")
if [[ -n "$CONTEXT1_NAMES" ]]; then
  LATEXDIFF_ARGS+=(--append-context1cmd="$CONTEXT1_NAMES")
fi

DIFF_TEX="$NEW_DIR/main_diff.tex"
latexdiff "${LATEXDIFF_ARGS[@]}" "$OLD_DIR/main.tex" "$NEW_DIR/main.tex" > "$DIFF_TEX"

if [[ -n "$CONTEXT1_NAMES" ]]; then
  python3 "$SCRIPT_DIR/latexdiff_notes.py" rewrite "$DIFF_TEX" --names-file "$NAMES_FILE"
  # Splice the generated \<name>del macro definitions in just before
  # \begin{document} (after \note and its wrappers are defined, which is
  # all \newcommand needs at definition time).
  python3 - "$DIFF_TEX" "$MACROS_FILE" <<'PYEOF'
import sys
diff_path, macros_path = sys.argv[1], sys.argv[2]
diff_text = open(diff_path, encoding="utf-8").read()
macros_text = open(macros_path, encoding="utf-8").read()
marker = "\\begin{document}"
idx = diff_text.index(marker)
diff_text = diff_text[:idx] + macros_text + "\n" + diff_text[idx:]
open(diff_path, "w", encoding="utf-8").write(diff_text)
PYEOF
fi

if ! ( cd "$NEW_DIR" && latexmk -pdf -shell-escape -interaction=nonstopmode main_diff.tex \
       > build.log 2>&1 ); then
  echo "latexmk failed; tail of $NEW_DIR/build.log:" >&2
  tail -n 40 "$NEW_DIR/build.log" >&2
  exit 1
fi

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
OUT_NAME="main_diff_$(sanitize "$OLD_REF")_vs_$(sanitize "$NEW_REF").pdf"
cp "$NEW_DIR/main_diff.pdf" "$BUILD_DIR/$OUT_NAME"
echo "Wrote $BUILD_DIR/$OUT_NAME"
