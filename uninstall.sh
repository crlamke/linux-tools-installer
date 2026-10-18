#!/usr/bin/env bash
#
# uninstall.sh - remove what install.sh installed, and take the install
#                directory (and its script folders) off your PATH.
#
# Usage:
#   uninstall.sh [-d DIR] [-s] [-y] [-n] [-f] [-h]
#
# Only what is listed in the install manifest is removed: the installed
# files, symlinks and folders, never anything else. Files you changed since
# installing are kept unless you use -f, and installed folders are only
# removed once empty, so anything you added yourself stays. The PATH block
# added by install.sh is removed from the shell startup files (or
# /etc/profile.d) it was added to, if it still points at this install.
# The install directory itself is removed once it is empty.
#
# Options:
#   -d DIR   install directory (default: the folder this script is in if it
#            holds an install, else ~/.local/k-tools, or /opt/k-tools with -s)
#   -s       the install was system-wide (/opt/k-tools); needs root
#   -y       yes: don't ask for confirmation (needed when not run from a terminal)
#   -n       dry run: show what would be removed, change nothing
#   -f       also remove files you changed since installing
#   -h       show this help
#
# Exit codes: 0 done, 1 usage error, nothing installed, or declined;
# 2 not permitted (e.g. system install without root).

set -euo pipefail

PKG="k-tools"
MANIFEST=".install-manifest"
PROG="$(basename "$0")"
HERE="$(cd "$(dirname "$0")" && pwd -P)"

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

if [[ -z "$dest" ]]; then
    if [[ -f "$HERE/$MANIFEST" ]]; then dest="$HERE"
    elif (( system )); then dest="/opt/$PKG"
    else dest="$HOME/.local/$PKG"; fi
fi
[[ "$dest" == /* ]] || dest="$PWD/$dest"
dest="${dest%/}"
[[ -f "$dest/$MANIFEST" ]] || die 1 "no $PKG install found in '$dest' (no $MANIFEST there); use -d to point at it"

# ---------------------------------------------------------------- read manifest
safe_rel() { case "$1" in ""|/*|..|../*|*/../*|*/..) die 2 "manifest has an unsafe path '$1'; not touching anything" ;; esac; }
mode=user; rc_files=(); files=(); links=(); dirs=(); declare -A sum=()
while IFS= read -r line; do
    case "$line" in
        "#mode "*) mode=${line#\#mode } ;;
        "#rc "*)   rc_files+=("${line#\#rc }") ;;
        "#pkg "*)  PKG=${line#\#pkg } ;;
        "#dir "*)  rel=${line#\#dir }; safe_rel "$rel"; dirs+=("$rel") ;;
        \#*|"")    ;;
        "link  "*) rel=${line#link  }; safe_rel "$rel"; links+=("$rel") ;;
        *)         rel=${line#*  }; safe_rel "$rel"; files+=("$rel"); sum["$rel"]=${line%%  *} ;;
    esac
done < "$dest/$MANIFEST"
if [[ "$mode" == system ]] && (( EUID != 0 )) && (( ! dry_run )); then
    die 2 "this is a system-wide install; run: sudo $0"
fi

remove=(); changed=(); missing=()
for rel in ${files[@]+"${files[@]}"}; do
    if [[ ! -e "$dest/$rel" ]]; then missing+=("$rel"); continue; fi
    if [[ -L "$dest/$rel" || ! -f "$dest/$rel" ]]; then changed+=("$rel"); continue; fi   # replaced by something else
    if [[ "$(sha256sum < "$dest/$rel" | cut -d' ' -f1)" == "${sum[$rel]}" ]] || (( force )); then
        remove+=("$rel")
    else
        changed+=("$rel")
    fi
done
rm_links=()
for rel in ${links[@]+"${links[@]}"}; do
    if [[ -L "$dest/$rel" ]]; then rm_links+=("$rel"); fi
done

begin="# >>> $PKG PATH >>>"
end="# <<< $PKG PATH <<<"

# ---------------------------------------------------------------- confirm
say "Uninstalling $PKG from $dest"
say "  remove:  ${#remove[@]} files, ${#rm_links[@]} symlinks, and the ${#dirs[@]} installed folders once empty"
for rel in ${remove[@]+"${remove[@]}"}; do say "    $rel"; done
for rel in ${rm_links[@]+"${rm_links[@]}"}; do say "    $rel (symlink)"; done
for rel in ${changed[@]+"${changed[@]}"}; do say "  keep    $rel  (changed since install; -f removes it too)"; done
if (( ${#missing[@]} )); then say "  already gone: ${missing[*]}"; fi
for rc in ${rc_files[@]+"${rc_files[@]}"}; do say "  PATH:    remove the $PKG block from $rc"; done

if (( dry_run )); then say "Dry run: nothing changed."; exit 0; fi
if (( ! assume_yes )); then
    { : < /dev/tty; } 2>/dev/null || die 1 "not uninstalling without confirmation; run from a terminal or add -y"
    read -r -p "Continue? [y/N] " answer < /dev/tty
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || { say "Nothing removed."; exit 1; }
fi

# ---------------------------------------------------------------- PATH
esc() { printf '%s' "$1" | sed 's/[][\\/.*^$]/\\&/g'; }
for rc in ${rc_files[@]+"${rc_files[@]}"}; do
    [[ -f "$rc" ]] || continue
    if [[ "$mode" == system && "$rc" == /etc/profile.d/* ]]; then
        if grep -qF "'$dest'" "$rc"; then rm -f -- "$rc"; fi
    elif grep -qF "$begin" "$rc"; then
        # Only remove the block if it points at THIS install (installing
        # elsewhere later moves the block to the newer folder).
        block=$(sed -n "/^$(esc "$begin")/,/^$(esc "$end")/p" "$rc")
        if [[ "$block" == *" '$dest'"* ]]; then
            tmp=$(mktemp)
            sed "/^$(esc "$begin")/,/^$(esc "$end")/d" "$rc" > "$tmp"
            cat "$tmp" > "$rc"; rm -f "$tmp"
        else
            say "  left the $PKG PATH block in $rc alone: it points at a different install"
        fi
    fi
done

# ---------------------------------------------------------------- files, links, folders
for rel in ${remove[@]+"${remove[@]}"}; do rm -f -- "$dest/$rel"; done
for rel in ${rm_links[@]+"${rm_links[@]}"}; do rm -f -- "$dest/$rel"; done
# Installed folders, deepest first, only if empty (keeps anything you added).
while IFS= read -r rel; do
    if [[ -n "$rel" && -d "$dest/$rel" && ! -L "$dest/$rel" ]]; then rmdir -- "$dest/$rel" 2>/dev/null || true; fi
done < <(printf '%s\n' ${dirs[@]+"${dirs[@]}"} | sort -r)
# Parent folders of removed files that were not recorded (older manifests).
for rel in ${remove[@]+"${remove[@]}"} ${rm_links[@]+"${rm_links[@]}"}; do
    d=$(dirname -- "$rel")
    while [[ "$d" != . ]]; do rmdir -- "$dest/$d" 2>/dev/null || break; d=$(dirname -- "$d"); done
done

if (( ${#changed[@]} == 0 )); then
    rm -f -- "$dest/$MANIFEST" "$dest/uninstall.sh"
else
    # Keep a manifest of what's left so a later 'uninstall.sh -f' can finish.
    tmp=$(mktemp "$dest/.manifest.XXXXXX")
    {
        grep '^#' "$dest/$MANIFEST"
        for rel in "${changed[@]}"; do printf '%s  %s\n' "${sum[$rel]}" "$rel"; done
    } > "$tmp"
    mv -f "$tmp" "$dest/$MANIFEST"
fi
rmdir -- "$dest" 2>/dev/null || true

if [[ -d "$dest" ]]; then
    say "Done. $dest still holds things that weren't removed:"
    find "$dest" -mindepth 1 -maxdepth 3 ! -name "$MANIFEST" ! -name uninstall.sh | sed "s#^$dest/#  #"
else
    say "Done. Removed $dest."
fi
case ":$PATH:" in
    *":$dest:"*) say "This shell still has it on PATH until you open a new terminal." ;;
esac
