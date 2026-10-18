#!/usr/bin/env bash
#
# install.sh - install the files and folders next to this script into one
#              directory and add it (and its script folders) to your PATH.
#
# Usage:
#   ./install.sh [-d DIR] [-s] [-y] [-n] [-f] [-h]
#
# Everything next to this script is installed, keeping its folder structure:
# scripts, folders full of scripts, data files, empty folders, hidden files
# (e.g. config/.env) and symlinks. Skipped: install.sh, uninstall.sh, .git
# folders and editor backups (*~, *.swp). Files with a #! line or that are
# already executable here are installed executable; everything else (data,
# libraries that are only sourced) is installed read/write, not executable.
# A copy of uninstall.sh goes into the install directory so you can remove
# everything later, even without this folder.
#
# PATH: the install directory and every installed folder that contains
# executables (e.g. bin/, nifi-tools/) are added; data-only folders are not.
# They go in one marked block in ~/.bashrc (and ~/.zshrc if you have one):
#   # >>> cli-tools PATH >>> ...  # <<< cli-tools PATH <<<
# Running install.sh again updates the files and keeps exactly one block.
# Open a new terminal (or 'source ~/.bashrc') to pick up the new PATH.
#
# Options:
#   -d DIR   install directory (default: ~/.local/cli-tools, or /opt/cli-tools with -s)
#   -s       system-wide install for all users (run as root): PATH is set in
#            /etc/profile.d/cli-tools.sh instead of your shell startup files
#   -y       yes: don't ask for confirmation (needed when not run from a terminal)
#   -n       dry run: show what would happen, change nothing
#   -f       allow installing into an existing directory that has other files
#   -h       show this help
#
# Reinstalling/upgrading: files, links and folders that were installed before
# but are no longer here are removed (files only if you haven't changed them).
#
# Exit codes: 0 done, 1 usage error or declined, 2 not permitted (e.g. -s
# without root, unsafe install directory), 3 copy failed.

set -euo pipefail

PKG="cli-tools"                       # used in default paths and PATH markers
MANIFEST=".install-manifest"
PROG="$(basename "$0")"
SRC="$(cd "$(dirname "$0")" && pwd -P)"

dest=""
system=0
assume_yes=0
dry_run=0
force=0

usage() { sed -n '3,/^$/p' "$0" | sed -e 's/^# \{0,1\}//'; }
say()   { printf '%s\n' "$*"; }
die()   { local code=$1; shift; printf '%s: error: %s\n' "$PROG" "$*" >&2; exit "$code"; }

while getopts ":d:synfh" opt; do
    case "$opt" in
        d) dest=$OPTARG ;;
        s) system=1 ;;
        y) assume_yes=1 ;;
        n) dry_run=1 ;;
        f) force=1 ;;
        h) usage; exit 0 ;;
        :) die 1 "option -$OPTARG needs a value (see $PROG -h)" ;;
        *) die 1 "unknown option -$OPTARG (see $PROG -h)" ;;
    esac
done
shift $((OPTIND - 1))
(( $# == 0 )) || die 1 "unexpected argument '$1' (see $PROG -h)"

if (( system )) && (( EUID != 0 )) && (( ! dry_run )); then
    die 2 "-s (system-wide) needs root; run: sudo $0 -s"
fi
if [[ -z "$dest" ]]; then
    if (( system )); then dest="/opt/$PKG"; else dest="$HOME/.local/$PKG"; fi
fi

# ---------------------------------------------------------------- install dir
[[ "$dest" == /* ]] || dest="$PWD/$dest"
dest="${dest%/}"
case "$dest" in
    *$'\n'*|*"'"*|*'"'*|*'$'*|*'`'*|*\\*|*:*)
        die 1 "the install directory can't contain quotes, \$, \`, \\, : or newlines (they would break the PATH line)" ;;
esac
case "$dest" in
    ""|/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/bin|/usr/local|/usr/local/bin|/var)
        die 2 "refusing to install into '$dest' itself; use a dedicated folder such as $dest/$PKG" ;;
esac
[[ "$dest" != "${HOME%/}" ]] || die 2 "refusing to install into your home folder itself; use e.g. $HOME/.local/$PKG"
[[ "$dest" != "$SRC" && "$dest/" != "$SRC/"* ]] || die 1 "the install directory is inside this folder; pick another with -d"

# ---------------------------------------------------------------- what to install
# Executable = has a #! line, or is already executable here.
is_exec() { [[ -x "$1" ]] || [[ "$(head -c 2 "$1" 2>/dev/null)" == '#!' ]]; }

files=(); links=(); dirs=()
declare -A path_dirs=()
while IFS= read -r -d '' f; do
    rel=${f#"$SRC"/}
    case "$rel" in
        install.sh|uninstall.sh|"$MANIFEST") continue ;;
        *~|*.swp|.DS_Store|*/.DS_Store) continue ;;
    esac
    case "$rel" in *$'\n'*|*$'\t'*) die 1 "file names with tabs or newlines are not supported: $rel" ;; esac
    if [[ -L "$f" ]]; then
        links+=("$rel")
        # a link to a script makes its folder a script folder
        if [[ -f "$f" ]] && is_exec "$f"; then path_dirs["$(dirname -- "$rel")"]=1; fi
    elif [[ -d "$f" ]]; then
        dirs+=("$rel")
    elif [[ -f "$f" ]]; then
        files+=("$rel")
        if is_exec "$f"; then path_dirs["$(dirname -- "$rel")"]=1; fi
    fi
done < <(find "$SRC" -mindepth 1 \( -name .git -o -name .svn -o -name .hg \) -prune -o -print0 | sort -z)
(( ${#files[@]} + ${#links[@]} )) || die 1 "no files to install next to $PROG"
[[ -f "$SRC/uninstall.sh" ]] || die 1 "uninstall.sh is missing from $SRC"

# The install dir always goes on PATH; plus every folder holding executables.
path_list=("$dest")
while IFS= read -r d; do
    [[ -n "$d" && "$d" != . ]] && path_list+=("$dest/$d")
done < <(printf '%s\n' "${!path_dirs[@]}" | sort)

# Existing install? Read its manifest so an upgrade can remove dropped items.
old_files=(); old_links=(); old_dirs=(); declare -A old_sum=()
if [[ -f "$dest/$MANIFEST" ]]; then
    while IFS= read -r line; do
        case "$line" in
            "#dir "*) old_dirs+=("${line#\#dir }") ;;
            \#*|"") ;;
            "link  "*) old_links+=("${line#link  }") ;;
            *) rel=${line#*  }; old_files+=("$rel"); old_sum["$rel"]=${line%%  *} ;;
        esac
    done < "$dest/$MANIFEST"
elif [[ -d "$dest" ]] && [[ -n "$(ls -A "$dest" 2>/dev/null)" ]] && (( ! force )); then
    die 2 "'$dest' already exists and has other files in it; use -f to install there anyway, or pick another folder with -d"
fi
declare -A new_set=()
for rel in ${files[@]+"${files[@]}"} ${links[@]+"${links[@]}"} ${dirs[@]+"${dirs[@]}"}; do new_set["$rel"]=1; done
dropped_files=(); dropped_links=(); dropped_dirs=()
for rel in ${old_files[@]+"${old_files[@]}"}; do [[ -n "${new_set[$rel]:-}" ]] || dropped_files+=("$rel"); done
for rel in ${old_links[@]+"${old_links[@]}"}; do [[ -n "${new_set[$rel]:-}" ]] || dropped_links+=("$rel"); done
for rel in ${old_dirs[@]+"${old_dirs[@]}"};   do [[ -n "${new_set[$rel]:-}" ]] || dropped_dirs+=("$rel"); done

# ---------------------------------------------------------------- PATH plan
begin="# >>> $PKG PATH >>>"
end="# <<< $PKG PATH <<<"
quoted_dirs=""
for d in "${path_list[@]}"; do quoted_dirs+=" '$d'"; done
path_block="$begin (added by install.sh; removed by uninstall.sh)
for _${PKG//-/_}_dir in$quoted_dirs; do
    case \":\${PATH}:\" in
        *\":\$_${PKG//-/_}_dir:\"*) ;;
        *) PATH=\"\${PATH:+\$PATH:}\$_${PKG//-/_}_dir\" ;;
    esac
done
export PATH; unset _${PKG//-/_}_dir
$end"

rc_files=()
if (( system )); then
    rc_files=("/etc/profile.d/$PKG.sh")
else
    rc_files=("$HOME/.bashrc")
    if [[ -f "$HOME/.zshrc" ]]; then rc_files+=("$HOME/.zshrc"); fi
fi

# ---------------------------------------------------------------- confirm
n_exec=0; for rel in ${files[@]+"${files[@]}"}; do if is_exec "$SRC/$rel"; then n_exec=$((n_exec+1)); fi; done
say "Installing $PKG from $SRC"
say "  into:      $dest"
say "  contents:  ${#files[@]} files ($n_exec executable), ${#dirs[@]} folders, ${#links[@]} symlinks"
for rel in ${files[@]+"${files[@]}"}; do
    if is_exec "$SRC/$rel"; then say "    $rel  (executable)"; else say "    $rel"; fi
done
for rel in ${links[@]+"${links[@]}"}; do say "    $rel -> $(readlink "$SRC/$rel")"; done
if (( ${#dropped_files[@]} + ${#dropped_links[@]} + ${#dropped_dirs[@]} )); then
    say "  removing items no longer in the package: ${dropped_files[*]} ${dropped_links[*]} ${dropped_dirs[*]}"
fi
say "  PATH:      add ${path_list[*]}"
say "             via ${rc_files[*]}"

if (( dry_run )); then say "Dry run: nothing changed."; exit 0; fi
if (( ! assume_yes )); then
    { : < /dev/tty; } 2>/dev/null || die 1 "not installing without confirmation; run from a terminal or add -y"
    read -r -p "Continue? [y/N] " answer < /dev/tty
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || { say "Nothing installed."; exit 1; }
fi

# ---------------------------------------------------------------- copy
mkdir -p "$dest" || die 3 "cannot create $dest"
for rel in ${dirs[@]+"${dirs[@]}"}; do
    if [[ -L "$dest/$rel" || ( -e "$dest/$rel" && ! -d "$dest/$rel" ) ]]; then rm -f -- "$dest/$rel"; fi
    mkdir -p "$dest/$rel" || die 3 "could not create folder $rel"
done
for rel in ${files[@]+"${files[@]}"}; do
    mode=644; if is_exec "$SRC/$rel"; then mode=755; fi
    if [[ -L "$dest/$rel" ]]; then rm -f -- "$dest/$rel"; fi
    install -D -p -m "$mode" "$SRC/$rel" "$dest/$rel" || die 3 "could not copy $rel"
done
for rel in ${links[@]+"${links[@]}"}; do
    mkdir -p "$(dirname -- "$dest/$rel")"
    if [[ -d "$dest/$rel" && ! -L "$dest/$rel" ]]; then
        die 3 "can't install symlink $rel: a real folder is in the way at $dest/$rel (move it aside first)"
    fi
    rm -f -- "$dest/$rel"
    cp -P -- "$SRC/$rel" "$dest/$rel" || die 3 "could not copy symlink $rel"
done
install -m 755 "$SRC/uninstall.sh" "$dest/uninstall.sh" || die 3 "could not copy uninstall.sh"

# Upgrade: remove items dropped from the package (files only if unchanged).
for rel in ${dropped_files[@]+"${dropped_files[@]}"}; do
    [[ -f "$dest/$rel" && ! -L "$dest/$rel" ]] || continue
    if [[ "$(sha256sum < "$dest/$rel" | cut -d' ' -f1)" == "${old_sum[$rel]}" ]]; then
        rm -f -- "$dest/$rel"
    else
        say "  kept $dest/$rel (you changed it; it is no longer part of the package)"
    fi
done
for rel in ${dropped_links[@]+"${dropped_links[@]}"}; do
    if [[ -L "$dest/$rel" ]]; then rm -f -- "$dest/$rel"; fi
done
while IFS= read -r rel; do      # deepest first; only if empty
    [[ -n "$rel" ]] && rmdir -- "$dest/$rel" 2>/dev/null || true
done < <(printf '%s\n' ${dropped_dirs[@]+"${dropped_dirs[@]}"} | sort -r)

# Manifest: how it was installed, then one line per installed item.
tmp_manifest=$(mktemp "$dest/.manifest.XXXXXX")
{
    printf '# %s install manifest, written %s by install.sh\n' "$PKG" "$(date '+%F %T')"
    printf '#pkg %s\n#mode %s\n' "$PKG" "$( (( system )) && echo system || echo user)"
    for rc in "${rc_files[@]}"; do printf '#rc %s\n' "$rc"; done
    for d in "${path_list[@]}"; do printf '#path %s\n' "$d"; done
    for rel in ${dirs[@]+"${dirs[@]}"}; do printf '#dir %s\n' "$rel"; done
    for rel in ${files[@]+"${files[@]}"}; do
        printf '%s  %s\n' "$(sha256sum < "$dest/$rel" | cut -d' ' -f1)" "$rel"
    done
    for rel in ${links[@]+"${links[@]}"}; do printf 'link  %s\n' "$rel"; done
} > "$tmp_manifest"
mv -f "$tmp_manifest" "$dest/$MANIFEST"
chmod 644 "$dest/$MANIFEST"

# ---------------------------------------------------------------- PATH
esc() { printf '%s' "$1" | sed 's/[][\\/.*^$]/\\&/g'; }
for rc in "${rc_files[@]}"; do
    if (( system )); then
        printf '%s\n' "$path_block" > "$rc"
        chmod 644 "$rc"
        continue
    fi
    touch "$rc"
    if grep -qF "$begin" "$rc"; then
        # Replace our old block (keeps a single block on reinstall).
        tmp=$(mktemp)
        sed "/^$(esc "$begin")/,/^$(esc "$end")/d" "$rc" > "$tmp"
        cat "$tmp" > "$rc"; rm -f "$tmp"
    else
        cp -p "$rc" "$rc.before-$PKG" 2>/dev/null || true
    fi
    # Make sure the block starts on its own line.
    if [[ -s "$rc" && "$(tail -c 1 "$rc")" != "" ]]; then printf '\n' >> "$rc"; fi
    printf '%s\n' "$path_block" >> "$rc"
done

say "Done. Installed ${#files[@]} files, ${#dirs[@]} folders and ${#links[@]} symlinks in $dest."
case ":$PATH:" in
    *":$dest:"*) say "It is already on this shell's PATH." ;;
    *) if (( system )); then
           say "New login shells will have it on PATH. For this shell, log out and back in."
       else
           say "Open a new terminal, or run:  source ~/.bashrc"
       fi ;;
esac
say "To remove it later:  $dest/uninstall.sh"
