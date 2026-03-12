#!/usr/bin/env bash
set -euo pipefail

#===============================================================================
# vcpkg_enumerated_install
#
# Search vcpkg ports, show enumerated results, and install selected entries.
#
# Usage:
#   vcpkg_enumerated_install [options] [search term]
#
# Options:
#   --keep-going   Continue installation if one port fails.
#   --recursive    Install dependencies recursively.
#   --upgrade      Upgrade the port if already installed.
#   -h, --help     Show help and exit.
#
# Examples:
#   vcpkg_enumerated_install
#   vcpkg_enumerated_install boost
#   vcpkg_enumerated_install --recursive --keep-going --upgrade libpng
#
# Notes:
#   - The script accepts comma-separated indices, space-separated indices,
#     and ranges such as: 1,2 4-6
#   - It assumes the port name is the first whitespace-delimited field in
#     each vcpkg search result line.
#===============================================================================

#-------------------------------------------------------------------------------
# Globals
#-------------------------------------------------------------------------------
KEEP_GOING=0
RECURSIVE=0
UPGRADE=0
SEARCH_TERM=""

#-------------------------------------------------------------------------------
# show_help
#-------------------------------------------------------------------------------
function show_help() {
  cat <<'EOF'
vcpkg_enumerated_install

Usage:
  vcpkg_enumerated_install [options] [search term]

Options:
  --keep-going   Continue installation if one port fails.
  --recursive    Install dependencies recursively.
  --upgrade      Upgrade the port if already installed.
  -h, --help     Show this help text.

Examples:
  vcpkg_enumerated_install
      Prompt for the search term interactively.

  vcpkg_enumerated_install boost
      Search for "boost".

  vcpkg_enumerated_install --recursive --keep-going --upgrade libpng
      Search for "libpng" and install with extra flags.
EOF
}

#-------------------------------------------------------------------------------
# require_command
#-------------------------------------------------------------------------------
function require_command() {
  local cmd="$1"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'Error: required command not found: %s\n' "$cmd" >&2
    exit 1
  fi
}

#-------------------------------------------------------------------------------
# parse_args
#-------------------------------------------------------------------------------
function parse_args() {
  local -a search_parts=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-going)
        KEEP_GOING=1
        shift
        ;;
      --recursive)
        RECURSIVE=1
        shift
        ;;
      --upgrade)
        UPGRADE=1
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        search_parts+=( "$1" )
        shift
        ;;
    esac
  done

  SEARCH_TERM="${search_parts[*]:-}"
}

#-------------------------------------------------------------------------------
# collect_selection_indices
#-------------------------------------------------------------------------------
function collect_selection_indices() {
  local selection="$1"
  local -n out_ref="$2"
  local -a tokens=()
  local token=""
  local start=0
  local end=0
  local idx=0

  out_ref=()

  IFS=' ,' read -r -a tokens <<< "$selection"

  for token in "${tokens[@]}"; do
    if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"

      if (( start <= end )); then
        for (( idx = start; idx <= end; idx++ )); do
          out_ref+=( "$idx" )
        done
      else
        printf 'Ignoring invalid range: %s\n' "$token" >&2
      fi
    elif [[ "$token" =~ ^[0-9]+$ ]]; then
      out_ref+=( "$token" )
    fi
  done

  if (( ${#out_ref[@]} > 0 )); then
    mapfile -t out_ref < <(
      printf '%s\n' "${out_ref[@]}" |
        sort -n -u
    )
  fi
}

#-------------------------------------------------------------------------------
# search_and_install
#-------------------------------------------------------------------------------
function search_and_install() {
  local term="$1"
  local search_results=""
  local selection=""
  local selection_prompt=""
  local port_name=""
  local idx=0
  local i=0

  local -a lines=()
  local -a chosen_indices=()
  local -a install_args=()

  if [[ -z "$term" ]]; then
    read -r -p "Enter the search term for vcpkg: " term
  fi

  printf "Searching for '%s'...\n" "$term"

  search_results="$(
    vcpkg search "$term" | cat 2>/dev/null
  )"

  if [[ -z "$search_results" ]]; then
    printf "No results found for '%s'.\n" "$term"
    return 0
  fi

  mapfile -t lines < <(
    printf '%s\n' "$search_results" |
      grep -vE \
        -e '^The result may be outdated' \
        -e '^If your port is not listed' \
        -e '^Run `git pull`' |
      sed '/^[[:space:]]*$/d'
  )

  if (( ${#lines[@]} == 0 )); then
    printf "No valid entries found for '%s'.\n" "$term"
    return 0
  fi

  printf 'Found the following entries:\n'
  for (( i = 0; i < ${#lines[@]}; i++ )); do
    printf '[%d] %s\n' "$i" "${lines[i]}"
  done

  printf -v selection_prompt '%s' \
    "Enter the indices to install " \
    "(comma/space-separated, e.g. 1,2 3-5, " \
    "or 'q' to quit): "

  read -r -p "$selection_prompt" selection

  if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
    printf 'Exiting without installing.\n'
    return 0
  fi

  collect_selection_indices "$selection" chosen_indices

  if (( ${#chosen_indices[@]} == 0 )); then
    printf 'No valid indices were selected.\n'
    return 0
  fi

  if (( KEEP_GOING )); then
    install_args+=( "--keep-going" )
  fi

  if (( RECURSIVE )); then
    install_args+=( "--recursive" )
  fi

  if (( UPGRADE )); then
    install_args+=( "--upgrade" )
  fi

  for idx in "${chosen_indices[@]}"; do
    if (( idx < 0 || idx >= ${#lines[@]} )); then
      printf 'Invalid index: %s. Skipping.\n' "$idx" >&2
      continue
    fi

    port_name="$(awk '{print $1}' <<< "${lines[idx]}")"

    printf "Installing '%s'...\n" "$port_name"
    vcpkg install "$port_name" "${install_args[@]}"
  done
}

#-------------------------------------------------------------------------------
# main
#-------------------------------------------------------------------------------
function main() {
  require_command "vcpkg"
  parse_args "$@"
  search_and_install "$SEARCH_TERM"
}

main "$@"
