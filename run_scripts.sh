#!/usr/bin/env bash
# Run one or more ChimeraX .cxc scripts headlessly.
#
# Usage:
#   ./run_scripts.sh                 # run all scripts in scripts/
#   ./run_scripts.sh 3j2w 6nk7       # run scripts matching these names
#   CHIMERAX=/path/to/chimerax ./run_scripts.sh
#
# Must be run from the repo root — scripts use paths relative to the working directory.

set -euo pipefail

# Resolve repo root (directory containing this script) and cd into it
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# === LOCATE ChimeraX BINARY ===
# Override by setting CHIMERAX env var; otherwise try common locations
if [[ -n "${CHIMERAX:-}" ]]; then
    CHIMERAX_BIN="$CHIMERAX"
elif command -v chimerax >/dev/null 2>&1; then
    CHIMERAX_BIN="chimerax"
elif command -v ChimeraX >/dev/null 2>&1; then
    CHIMERAX_BIN="ChimeraX"
else
    # Match /Applications/ChimeraX.app or any versioned bundle like /Applications/ChimeraX-1.11.app
    mac_candidates=( /Applications/ChimeraX*.app/Contents/MacOS/ChimeraX )
    CHIMERAX_BIN=""
    for candidate in "${mac_candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            CHIMERAX_BIN="$candidate"
            break
        fi
    done
fi

if [[ -z "${CHIMERAX_BIN:-}" ]]; then
    echo "Error: ChimeraX not found." >&2
    echo "Install ChimeraX or set CHIMERAX=/path/to/chimerax" >&2
    exit 1
fi

echo "Using ChimeraX: $CHIMERAX_BIN"

# === ENSURE OUTPUT DIRECTORIES EXIST ===
mkdir -p sessions images images/domains images/keys images/virions movies/domains cache views

# === PRE-FETCH PDB FILES ===
# ChimeraX's default fetch cache (~/Downloads/ChimeraX/PDB/) can be blocked by
# macOS sandboxing/TCC. Instead, we download each cif into the repo-local cache/
# directory and the .cxc scripts open it from there.
#
# Scans every scripts/*.cxc for `open ./cache/<name>.cif` references and fetches
# them from RCSB if not already present. Filenames follow RCSB conventions:
#   <pdbid>.cif              → asymmetric unit
#   <pdbid>-assembly<N>.cif  → biological assembly N
fetch_pdb_files() {
    local cif_files
    cif_files=$(grep -hoE 'cache/[A-Za-z0-9_-]+\.cif' scripts/*.cxc 2>/dev/null \
        | sed 's|cache/||' | sort -u)

    if [[ -z "$cif_files" ]]; then
        return 0
    fi

    while IFS= read -r filename; do
        local target="cache/$filename"
        if [[ -f "$target" ]]; then
            echo "  cached: $filename"
            continue
        fi
        local url="https://files.rcsb.org/download/$filename"
        echo "  fetching: $url"
        if ! curl -fsSL "$url" -o "$target"; then
            echo "  FAILED to fetch $filename" >&2
            rm -f "$target"
            return 1
        fi
    done <<< "$cif_files"
}

echo ""
echo "Pre-fetching PDB files..."
fetch_pdb_files
echo "Cache contents:"
ls -1 cache/ 2>/dev/null | sed 's/^/  /' || echo "  (empty)"

# === COLLECT SCRIPTS TO RUN ===
if [[ $# -eq 0 ]]; then
    # No args: run every .cxc in scripts/
    SCRIPTS=()
    while IFS= read -r line; do
        SCRIPTS+=( "$line" )
    done < <(find scripts -maxdepth 1 -name '*.cxc' | sort)
else
    # Args: match each pattern against scripts/*.cxc
    SCRIPTS=()
    for pattern in "$@"; do
        matches=( scripts/*"$pattern"*.cxc )
        if [[ ! -e "${matches[0]}" ]]; then
            echo "Warning: no scripts matched '$pattern'" >&2
            continue
        fi
        SCRIPTS+=( "${matches[@]}" )
    done
fi

if [[ ${#SCRIPTS[@]} -eq 0 ]]; then
    echo "Error: no scripts to run." >&2
    exit 1
fi

# === RUN EACH SCRIPT ===
# ChimeraX exits 0 even when individual commands in a .cxc script error,
# so we also scan its output for error markers and count those as failures.
failed=0
for script in "${SCRIPTS[@]}"; do
    echo ""
    echo "=========================================="
    echo "Running: $script"
    echo "=========================================="

    log=$(mktemp)
    # No --offscreen / --nogui: macOS ChimeraX doesn't ship with OSMesa, so
    #   --offscreen fails to create a GL context and any graphics command
    #   (camera, view, save png) crashes. We run with the regular GUI so a
    #   real GL context exists; a window may briefly appear but --exit closes
    #   it as soon as the script finishes.
    # --cmd "cd ...": ensures ChimeraX starts in the repo root; the .cxc scripts
    #   themselves switch CWD to scripts/ when opened, so in-script paths are
    #   relative to scripts/ (i.e. ../cache, ../images, ../sessions).
    # Pre-tee grep filters out the benign template-fetch warnings caused by
    #   macOS blocking writes to ChimeraX's ~/Downloads cache.
    "$CHIMERAX_BIN" --cmd "cd '$REPO_ROOT'" --exit "$script" 2>&1 \
        | grep -v -e 'Loading template file failed' \
                  -e 'Unable to fetch template' \
                  -e 'Offscreen rendering is not available' \
                  -e 'Unable to load OpenGL library' \
        | tee "$log"
    exit_code=${PIPESTATUS[0]}

    if grep -Eiq '^(error|unable to open|command not found|file not found|no such file)' "$log"; then
        echo "FAILED: $script (errors found in output)" >&2
        failed=$((failed + 1))
    elif [[ $exit_code -ne 0 ]]; then
        echo "FAILED: $script (exit code $exit_code)" >&2
        failed=$((failed + 1))
    else
        echo "Done: $script"
    fi
    rm -f "$log"
done

echo ""
echo "=========================================="
echo "Finished: ${#SCRIPTS[@]} script(s), $failed failure(s)"
echo "=========================================="

exit "$failed"
