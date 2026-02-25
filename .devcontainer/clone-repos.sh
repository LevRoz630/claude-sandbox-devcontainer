#!/bin/bash
# Interactive repo cloning from GitHub
set -uo pipefail

CLONE_DIR="${1:-/home/vscode/projects}"
mkdir -p "$CLONE_DIR"

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
echo "Enter numbers to clone (e.g., 1,3,5 or 1-3 or 'all'):"
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

# Parse selection
selected=()
if [ "$selection" = "all" ]; then
    selected=("${repo_array[@]}")
else
    IFS=',' read -ra parts <<< "$selection"
    for part in "${parts[@]}"; do
        part=$(echo "$part" | tr -d ' ')
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=${BASH_REMATCH[1]}
            end=${BASH_REMATCH[2]}
            for ((j=start; j<=end; j++)); do
                idx=$((j - 1))
                if [ $idx -ge 0 ] && [ $idx -lt ${#repo_array[@]} ]; then
                    selected+=("${repo_array[$idx]}")
                fi
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            idx=$((part - 1))
            if [ $idx -ge 0 ] && [ $idx -lt ${#repo_array[@]} ]; then
                selected+=("${repo_array[$idx]}")
            fi
        fi
    done
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
