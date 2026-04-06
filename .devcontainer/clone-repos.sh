#!/bin/bash
# Interactive repo cloning from GitHub
set -uo pipefail

CLONE_DIR="${1:-$HOME/repos}"
mkdir -p "$CLONE_DIR"

# Pick up credentials written by setup-1password (may not be in current shell yet)
# shellcheck disable=SC1091
[ -f /run/credentials/op-env ] && source /run/credentials/op-env

# Check gh auth
if ! gh auth status &>/dev/null; then
    echo "Error: GitHub CLI not authenticated. Run setup-1password or set GITHUB_PERSONAL_ACCESS_TOKEN."
    exit 1
fi

echo "Fetching your repositories..."
repos=$(gh repo list --limit 50 --json nameWithOwner,pushedAt --jq 'sort_by(.pushedAt) | reverse | .[].nameWithOwner')

if [ -z "$repos" ]; then
    echo "No repositories found."
    exit 0
fi

# Display repos with numbers
echo ""
echo "Your repositories (sorted by recent activity):"
echo "------------------------------------------------"
i=1
declare -a repo_array
while IFS= read -r repo; do
    repo_array+=("$repo")
    echo "  $i) $repo"
    i=$((i + 1))
done <<< "$repos"

echo ""
echo "Enter numbers (1,3,5 or 1-3), a search word, or 'all':"
echo "Press Enter to skip."

# Handle non-interactive terminals
if [ -t 0 ]; then
    read -r selection
else
    echo "Error: Not running in interactive terminal. Run manually: clone-repos"
    exit 1
fi

if [ -z "$selection" ]; then
    echo "No repos selected."
    exit 0
fi

# Parse selection into numeric indices from a given array
# Usage: parse_numeric_selection "selection_string" array_elements...
parse_numeric_selection() {
    local sel="$1"
    shift
    local -a arr=("$@")
    local -a result=()

    if [ "$sel" = "all" ]; then
        result=("${arr[@]}")
    else
        IFS=',' read -ra parts <<< "$sel"
        for part in "${parts[@]}"; do
            part="${part// /}"
            if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                local start=${BASH_REMATCH[1]}
                local end=${BASH_REMATCH[2]}
                for ((j=start; j<=end; j++)); do
                    local idx=$((j - 1))
                    if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#arr[@]}" ]; then
                        result+=("${arr[$idx]}")
                    fi
                done
            elif [[ "$part" =~ ^[0-9]+$ ]]; then
                local idx=$((part - 1))
                if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#arr[@]}" ]; then
                    result+=("${arr[$idx]}")
                fi
            fi
        done
    fi

    printf '%s\n' "${result[@]}"
}

selected=()
if [ "$selection" = "all" ]; then
    selected=("${repo_array[@]}")
elif [[ "$selection" =~ [a-zA-Z] ]]; then
    # Word search: filter repos by case-insensitive substring match
    search_term="${selection,,}"
    declare -a matched=()
    for repo in "${repo_array[@]}"; do
        if [[ "${repo,,}" == *"$search_term"* ]]; then
            matched+=("$repo")
        fi
    done

    if [ ${#matched[@]} -eq 0 ]; then
        echo "No repos matching '$selection'."
        exit 0
    fi

    echo ""
    echo "Repos matching '$selection':"
    echo "------------------------------------------------"
    for k in "${!matched[@]}"; do
        echo "  $((k + 1))) ${matched[$k]}"
    done
    echo ""
    echo "Enter numbers to clone (e.g., 1,3 or 1-2 or 'all'):"
    read -r sub_selection

    if [ -z "$sub_selection" ]; then
        echo "No repos selected."
        exit 0
    fi

    while IFS= read -r line; do
        selected+=("$line")
    done < <(parse_numeric_selection "$sub_selection" "${matched[@]}")
else
    while IFS= read -r line; do
        selected+=("$line")
    done < <(parse_numeric_selection "$selection" "${repo_array[@]}")
fi

if [ ${#selected[@]} -eq 0 ]; then
    echo "No valid repos selected."
    exit 0
fi

# Clone selected repos
echo ""
echo "Cloning ${#selected[@]} repo(s) to $CLONE_DIR..."
cd "$CLONE_DIR" || exit 1

failed=0
for repo in "${selected[@]}"; do
    repo_name=$(basename "$repo")
    if [ -d "$repo_name" ]; then
        echo "Skipping $repo (already exists)"
    else
        echo "Cloning $repo..."
        if ! gh repo clone "$repo" -- --depth=1; then
            echo "Warning: Failed to clone $repo"
            failed=$((failed + 1))
        fi
    fi
done

echo ""
if [ $failed -gt 0 ]; then
    echo "Done with $failed error(s). Repos cloned to $CLONE_DIR"
else
    echo "Done! Repos cloned to $CLONE_DIR"
fi
