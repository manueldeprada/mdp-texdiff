# mdp-texdiff

A `latexdiff` wrapper that builds a diff PDF between two states of a LaTeX
project (two git refs, or a ref against your uncommitted working tree),
and correctly handles deleted [todonotes](https://ctan.org/pkg/todonotes)
author-note macros (`\alice{...}`, `\bob{...}`, or whatever your
coauthors' note commands are called) instead of crashing the build or
silently dropping them.

## Why

Plain `latexdiff` output usually builds fine, but if your paper uses
`todonotes` wrapper macros for margin comments (`\newcommand{\alice}[2][]{
\note[#1]{Alice}{yellow}{#2}}`-style), a fully deleted note trips a LaTeX
error: `latexdiff`'s usual trick for a deleted command is to wrap it in
`\DIFdel{...}`, which uses `ulem`'s `\sout`; `\sout` boxes its argument,
and `todonotes`' `\todo` calls `\marginpar` internally, which cannot run
inside a box ("not in outer par mode" / pgfkeys errors).

`latexdiff.sh` works around this by telling `latexdiff` to disable note
commands inside deleted spans (`--append-context1cmd`) and rewriting the
emitted plain-text markup into a call to a generated `\<name>del{}`
variant that renders as a gray struck-through bubble, with `\sout` only
around the note's own text argument. `latexdiff_notes.py` does the
discovery and rewriting; see the comments at the top of both files for
the mechanics.

If your document doesn't use `todonotes` wrapper macros at all, none of
this activates and you just get a normal `latexdiff` build.

## Requirements

- `bash`, `git`, `rsync`
- `python3` (3.7+, standard library only, no pip installs)
- A TeX Live install with `latexdiff` and `latexmk` on `PATH`
- Whatever the target document itself needs to build (e.g. if it uses
  `minted`, `latexmk` is invoked with `-shell-escape`, so you also need
  Pygments (`pygmentize`) on `PATH`)

## Install

There's nothing to build. Clone this repo, or just copy `latexdiff.sh`
and `latexdiff_notes.py` (they live next to each other; `latexdiff.sh`
calls the `.py` file by relative path) anywhere you like:

```
git clone https://github.com/manueldeprada/mdp-texdiff.git
```

The scripts don't need to live inside the target LaTeX repo, and don't
assume any particular directory name (no `tools/` folder required). You
can also drop them into a `tools/` subdirectory of your own paper repo if
you'd rather keep it version-controlled there; run them from anywhere,
they locate themselves via `$0`.

## Usage

Run from inside the target git repo (or any subdirectory of it):

```
latexdiff.sh [--tex-dir PATH] [OLD_REF] [NEW_REF]
```

`OLD_REF` defaults to `HEAD`, `NEW_REF` defaults to `WORKING`. Either
positional argument can be:

- any git ref: a commit, tag, or branch (`HEAD~3`, `v1.0`, `origin/main`, a
  commit SHA, ...);
- `WORKING` — the current working tree on disk, i.e. **all** uncommitted
  changes, staged and unstaged combined (what `git diff HEAD` shows);
- `STAGED` — the index, i.e. what's staged for the next commit (what
  `git diff --cached` shows). Built via `git write-tree`, which only
  writes an object to `.git/objects`; it never touches a ref, the index,
  or your working tree.

Output: `<this script's directory>/build/main_diff_<old>_vs_<new>.pdf`.

### Examples

| You want a diff of... | Command |
|---|---|
| Last commit vs. everything uncommitted (default) | `latexdiff.sh` |
| Last commit vs. only what's staged | `latexdiff.sh HEAD STAGED` |
| Staged changes vs. unstaged changes on top of them | `latexdiff.sh STAGED WORKING` |
| A few commits back vs. everything uncommitted | `latexdiff.sh HEAD~3` |
| Two tagged releases | `latexdiff.sh v1.0 v2.0` |
| A feature branch vs. main | `latexdiff.sh main my-feature-branch` |
| Any of the above, with the LaTeX sources in a named subdirectory | `latexdiff.sh --tex-dir paper HEAD STAGED` |

`latexdiff.sh HEAD~3` is shorthand for `latexdiff.sh HEAD~3 WORKING`
since `NEW_REF` defaults to `WORKING`; `OLD_REF` never defaults to
anything other than `HEAD`, so the first positional argument is always
what you're diffing *from*.

### Finding your LaTeX sources

The script needs to know which directory holds `main.tex`. It
auto-detects this by searching the target repo (via `git ls-files`) for a
tracked file literally named `main.tex`:

- exactly one match: used automatically, no flags needed.
- zero or more than one match (e.g. an old draft also named `main.tex`
  sitting in another directory): the script exits with an error listing
  the candidates it found. Resolve it with either:
  - `--tex-dir PATH` (relative to the repo root), or
  - the `TEX_DIR` environment variable.

### `TEXTCMD` (optional)

`latexdiff.sh` passes `--append-textcmd="$TEXTCMD"` to `latexdiff`, so
added/deleted text inside the named macros gets `latexdiff`'s inline
blue/red markup instead of the macro's own color/formatting silently
winning. Defaults to `claudetext,codextext` (color-wrapping macros used
in some of my papers to mark AI-generated text); harmless to leave at the
default if your document doesn't define these. Override for your own
project, e.g.:

```
TEXTCMD="highlightme,mynote" /path/to/latexdiff.sh
```

## For AI agents

- Entry point: `latexdiff.sh [--tex-dir PATH] [OLD_REF] [NEW_REF]`. No
  args = diff `HEAD` against the current working tree (including
  uncommitted changes) of whatever git repo the current working
  directory is inside.
- `OLD_REF`/`NEW_REF` accept a git ref, or the pseudo-refs `WORKING` (full
  uncommitted state) and `STAGED` (the index only). "diff the last commit
  against what's staged" is `latexdiff.sh HEAD STAGED`; "diff staged
  against unstaged" is `latexdiff.sh STAGED WORKING`.
- Prerequisites to check for before running: `latexdiff`, `latexmk`,
  `python3`, `rsync`, `git` on `PATH`; if the target document uses
  `minted`, also `pygmentize`.
- If the script exits with "multiple main.tex files found" or "no
  tracked main.tex found", re-run with `--tex-dir <path-relative-to-repo-root>`
  pointing at the directory that contains the paper's actual `main.tex`.
- Output PDF path is printed on the last line as `Wrote <path>`; it also
  always lands at `<script_dir>/build/main_diff_<old>_vs_<new>.pdf`.
- On failure during the LaTeX build step, the script prints the last 40
  lines of `latexmk`'s log to stderr before exiting non-zero; that's
  almost always enough to diagnose a missing package or a macro that
  doesn't exist in one of the two compared revisions.
- The script is read-only with respect to the target repo: it copies the
  LaTeX source directory into a temp dir (`mktemp -d`, cleaned up on
  exit) and builds there. It never modifies files in the repo you run it
  from, and never touches git state (no commits, no checkouts).
- Safe to call repeatedly / in a loop over several ref pairs; each run
  uses its own temp directory.

## License

MIT, see `LICENSE`.
