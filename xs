#!/usr/bin/env bash
# xmarks dispatcher: installed as xs, symlinked as xg/xl/xd.
# Makes the commands work in shells that never read .bashrc (e.g.
# `! xs ...` inside a Claude Code session). In interactive shells the
# sourced functions shadow these; that matters for xg, whose function
# form leaves you in the mark's directory — this one can't.
dir="$(dirname "$(readlink -f "$0" 2>/dev/null || readlink "$0" 2>/dev/null || echo "$0")")"
source "$dir/xmarks.sh"
"$(basename "$0")" "$@"
