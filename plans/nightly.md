# Implementation Plan: v0 self update

**Root Feature:** `v0-9c05`

## Overview

Add a `v0 self update` command that allows users to switch between stable releases, nightly builds, and specific versions. This includes:

1. Refactoring `v0 self` into a dedicated dispatcher script (`bin/v0-self`)
2. Creating the update command (`bin/v0-self-update`)
3. Adding a nightly build workflow to CI/CD
4. Supporting three update channels: `stable`, `nightly`, and specific versions

## Project Structure

```
bin/
  v0                  # Modified: delegates `self` to v0-self
  v0-self             # NEW: dispatcher for self subcommands
  v0-self-debug       # Existing (moved from direct dispatch)
  v0-self-update      # NEW: update command implementation
lib/
  update-common.sh    # NEW: shared update utilities

.github/workflows/
  release.yml         # Existing (stable releases)
  nightly.yml         # NEW: nightly builds
```

## Dependencies

- No new external dependencies
- Uses existing: `curl`, `tar`, `jq`, `sha256sum/shasum`
- GitHub API for release queries

## Implementation Phases

### Phase 1: Refactor `v0 self` Dispatch Structure

**Goal**: Create a dedicated `bin/v0-self` dispatcher to cleanly handle multiple self subcommands.

**Files to modify**:
- `bin/v0` - Simplify self dispatch to exec `v0-self`
- `bin/v0-self` - New dispatcher script

**Changes to `bin/v0`**:
```bash
# In the case statement, replace the entire 'self)' block with:
self)
  exec "${V0_DIR}/bin/v0-self" "$@"
  ;;
```

**New `bin/v0-self`**:
```bash
#!/bin/bash
# v0-self - Self-management commands (debug, update, version)

set -e

SOURCE="${BASH_SOURCE[0]}"
while [[ -L "${SOURCE}" ]]; do
  DIR="$(cd -P "$(dirname "${SOURCE}")" && pwd)"
  SOURCE="$(readlink "${SOURCE}")"
  [[ ${SOURCE} != /* ]] && SOURCE="${DIR}/${SOURCE}"
done
V0_DIR="$(cd -P "$(dirname "${SOURCE}")/.." && pwd)"

show_help() {
  cat <<'EOF'
v0 self - Self-management commands

Usage: v0 self <command> [args]

Commands:
  debug         Generate debug report for failed operations
  update        Update v0 to a different version
  version       Show current and available versions

Run 'v0 self <command> --help' for command-specific options.

Examples:
  v0 self update                 # Update to latest stable
  v0 self update nightly         # Switch to nightly channel
  v0 self update stable          # Switch to stable channel
  v0 self update 0.2.1           # Install specific version
  v0 self version                # Show version info
EOF
}

case "${1:-}" in
  debug)
    shift
    exec "${V0_DIR}/bin/v0-self-debug" "$@"
    ;;
  update)
    shift
    exec "${V0_DIR}/bin/v0-self-update" "$@"
    ;;
  version)
    shift
    exec "${V0_DIR}/bin/v0-self-version" "$@"
    ;;
  --help|-h|"")
    show_help
    exit 0
    ;;
  *)
    echo "Unknown self command: ${1}" >&2
    echo "Run 'v0 self --help' for usage" >&2
    exit 1
    ;;
esac
```

**Verification**:
- `v0 self --help` shows updated help with update command
- `v0 self debug --help` still works
- `v0 self-debug --help` still works (backward compat)

---

### Phase 2: Create Update Infrastructure

**Goal**: Build the core update logic in `bin/v0-self-update` with supporting utilities.

**New `lib/update-common.sh`**:
```bash
# Shared constants
V0_REPO="alfredjeanlab/v0"
GITHUB_API="https://api.github.com"
GITHUB_RELEASES="https://github.com/${V0_REPO}/releases"

# Get installation method (homebrew, direct, or unknown)
get_install_method() {
  local v0_path
  v0_path=$(command -v v0 2>/dev/null)

  if [[ "${v0_path}" == *"/Cellar/"* ]] || [[ "${v0_path}" == *"/homebrew/"* ]]; then
    echo "homebrew"
  elif [[ "${v0_path}" == *"/.local/"* ]]; then
    echo "direct"
  else
    echo "unknown"
  fi
}

# Get current installed version
get_current_version() {
  local version_file="${V0_DIR}/VERSION"
  if [[ -f "${version_file}" ]]; then
    cat "${version_file}"
  else
    echo "unknown"
  fi
}

# Get current channel (stable, nightly, or version)
get_current_channel() {
  local channel_file="${V0_DIR}/.channel"
  if [[ -f "${channel_file}" ]]; then
    cat "${channel_file}"
  else
    echo "stable"
  fi
}

# Query available versions from GitHub
list_available_versions() {
  curl -fsSL "${GITHUB_API}/repos/${V0_REPO}/releases" 2>/dev/null |
    jq -r '.[].tag_name' | sed 's/^v//' | head -10
}

# Get latest stable version
get_latest_stable() {
  curl -fsSL "${GITHUB_API}/repos/${V0_REPO}/releases/latest" 2>/dev/null |
    jq -r '.tag_name' | sed 's/^v//'
}

# Get latest nightly version
get_latest_nightly() {
  curl -fsSL "${GITHUB_API}/repos/${V0_REPO}/releases" 2>/dev/null |
    jq -r '[.[] | select(.tag_name | startswith("nightly-"))][0].tag_name // empty'
}
```

**New `bin/v0-self-update`** (core logic):
```bash
#!/bin/bash
# v0-self-update - Update v0 to a different version or channel

set -e

# ... (boilerplate: V0_DIR resolution, source common libs)

show_help() {
  cat <<'EOF'
v0 self update - Update v0 installation

Usage:
  v0 self update [channel|version]

Channels:
  stable        Latest stable release (default)
  nightly       Latest nightly build from development

Versions:
  <version>     Specific version (e.g., 0.2.0, 0.2.1-rc1)

Options:
  --list        Show available versions
  --check       Check for updates without installing
  --force       Force reinstall even if same version
  --help, -h    Show this help

Examples:
  v0 self update              # Update to latest stable
  v0 self update nightly      # Switch to nightly channel
  v0 self update stable       # Switch back to stable
  v0 self update 0.2.0        # Install specific version
  v0 self update --list       # Show available versions
  v0 self update --check      # Check what would be installed
EOF
}

do_update() {
  local target_version="$1"
  local tag_name="$2"  # May differ from version (e.g., "nightly-20260120")

  # Detect install method
  local install_method
  install_method=$(get_install_method)

  case "${install_method}" in
    homebrew)
      echo "Homebrew installation detected."
      echo "Please use: brew upgrade alfredjeanlab/tap/v0"
      echo ""
      echo "Or to use a specific version:"
      echo "  brew uninstall v0"
      echo "  curl -fsSL https://github.com/${V0_REPO}/releases/download/${tag_name}/install.sh | bash"
      exit 1
      ;;
    direct)
      perform_direct_update "${target_version}" "${tag_name}"
      ;;
    *)
      echo "Warning: Unknown installation method" >&2
      perform_direct_update "${target_version}" "${tag_name}"
      ;;
  esac
}

perform_direct_update() {
  local version="$1"
  local tag_name="$2"

  # Download and install using similar logic to install.sh
  # Key steps:
  # 1. Create temp directory
  # 2. Download tarball and checksum
  # 3. Verify checksum
  # 4. Backup current installation
  # 5. Extract new version
  # 6. Update symlink
  # 7. Write channel marker
}
```

**Key behaviors**:
- Detects Homebrew vs direct installation
- Homebrew users get instructions to use `brew upgrade`
- Direct install users get seamless update
- Writes `.channel` marker file to track stable/nightly preference

**Verification**:
- `v0 self update --help` shows usage
- `v0 self update --list` shows available versions
- `v0 self update --check` shows what would be installed

---

### Phase 3: Add Nightly Build Workflow

**Goal**: Create automated nightly builds from the main branch.

**New `.github/workflows/nightly.yml`**:
```yaml
name: Nightly Build

on:
  schedule:
    # Run at 2:00 AM UTC daily
    - cron: '0 2 * * *'
  workflow_dispatch:  # Allow manual trigger

permissions:
  contents: write

jobs:
  nightly:
    name: Create Nightly Release
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          ref: main

      - name: Check for changes since last nightly
        id: changes
        run: |
          # Get last nightly release date
          LAST_NIGHTLY=$(gh release list --limit 20 | grep nightly | head -1 | awk '{print $3}' || echo "")
          if [[ -z "$LAST_NIGHTLY" ]]; then
            echo "has_changes=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          # Check for commits since then
          COMMITS=$(git log --since="$LAST_NIGHTLY" --oneline | wc -l)
          if [[ "$COMMITS" -gt 0 ]]; then
            echo "has_changes=true" >> "$GITHUB_OUTPUT"
          else
            echo "has_changes=false" >> "$GITHUB_OUTPUT"
          fi
        env:
          GH_TOKEN: ${{ github.token }}

      - name: Generate nightly tag
        if: steps.changes.outputs.has_changes == 'true'
        id: tag
        run: |
          DATE=$(date -u '+%Y%m%d')
          SHORT_SHA=$(git rev-parse --short HEAD)
          TAG="nightly-${DATE}-${SHORT_SHA}"
          echo "tag=$TAG" >> "$GITHUB_OUTPUT"
          echo "version=nightly-${DATE}" >> "$GITHUB_OUTPUT"

      - name: Create tarball
        if: steps.changes.outputs.has_changes == 'true'
        run: |
          TAG="${{ steps.tag.outputs.tag }}"
          mkdir -p dist
          tar -czf "dist/v0-${TAG}.tar.gz" bin/ lib/ LICENSE VERSION

      - name: Generate checksums
        if: steps.changes.outputs.has_changes == 'true'
        run: |
          TAG="${{ steps.tag.outputs.tag }}"
          cd dist
          sha256sum "v0-${TAG}.tar.gz" > "v0-${TAG}.tar.gz.sha256"

      - name: Prepare install script
        if: steps.changes.outputs.has_changes == 'true'
        run: cp install.sh dist/install.sh

      - name: Delete old nightly releases
        if: steps.changes.outputs.has_changes == 'true'
        run: |
          # Keep only the 5 most recent nightlies
          gh release list --limit 50 | grep nightly | tail -n +6 | awk '{print $1}' | \
            xargs -I {} gh release delete {} --yes || true
        env:
          GH_TOKEN: ${{ github.token }}

      - name: Create GitHub Release
        if: steps.changes.outputs.has_changes == 'true'
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ steps.tag.outputs.tag }}
          name: Nightly ${{ steps.tag.outputs.version }}
          draft: false
          prerelease: true
          body: |
            Automated nightly build from `main` branch.

            **Commit**: ${{ github.sha }}
            **Date**: ${{ steps.tag.outputs.version }}

            ⚠️ This is an unstable development build. Use `v0 self update stable` to return to stable releases.
          files: |
            dist/v0-${{ steps.tag.outputs.tag }}.tar.gz
            dist/v0-${{ steps.tag.outputs.tag }}.tar.gz.sha256
            dist/install.sh
```

**Verification**:
- Manually trigger workflow from GitHub Actions
- Nightly release appears with `nightly-YYYYMMDD-SHA` tag
- Old nightlies are cleaned up (keep last 5)

---

### Phase 4: Version Display Command

**Goal**: Create `v0 self version` to show version info clearly.

**New `bin/v0-self-version`**:
```bash
#!/bin/bash
# v0-self-version - Show version information

set -e

# ... (boilerplate)

source "${V0_DIR}/lib/update-common.sh"

show_version_info() {
  local current_version latest_stable latest_nightly channel

  current_version=$(get_current_version)
  channel=$(get_current_channel)

  echo "v0 version ${current_version}"
  echo ""
  echo "Channel: ${channel}"
  echo "Install: $(get_install_method)"

  if [[ "${1:-}" == "--check" ]]; then
    echo ""
    echo "Checking for updates..."
    latest_stable=$(get_latest_stable)
    latest_nightly=$(get_latest_nightly)

    echo "Latest stable:  ${latest_stable:-unknown}"
    echo "Latest nightly: ${latest_nightly:-none}"

    if [[ "${channel}" == "stable" ]] && [[ "${current_version}" != "${latest_stable}" ]]; then
      echo ""
      echo "Update available: ${current_version} → ${latest_stable}"
      echo "Run: v0 self update"
    fi
  fi
}

case "${1:-}" in
  --check|-c)
    show_version_info --check
    ;;
  --help|-h)
    echo "Usage: v0 self version [--check]"
    echo ""
    echo "Show version information."
    echo "  --check    Also check for available updates"
    ;;
  *)
    show_version_info
    ;;
esac
```

**Update `bin/v0` show_version()**: Read from VERSION file instead of hardcoded string.

```bash
show_version() {
  local version_file="${V0_DIR}/VERSION"
  if [[ -f "${version_file}" ]]; then
    echo "v0 $(cat "${version_file}")"
  else
    echo "v0 unknown"
  fi
}
```

**Verification**:
- `v0 --version` shows version from VERSION file
- `v0 self version` shows detailed info
- `v0 self version --check` shows update availability

---

### Phase 5: Update install.sh for Nightly Support

**Goal**: Modify install.sh to support nightly channel installation.

**Changes to `install.sh`**:
```bash
# Add channel support
V0_CHANNEL="${V0_CHANNEL:-stable}"

# Resolve version based on channel
if [ "$V0_VERSION" = "latest" ]; then
  case "$V0_CHANNEL" in
    nightly)
      info "Fetching latest nightly version..."
      V0_VERSION=$(curl -fsSL "${GITHUB_API}/repos/${V0_REPO}/releases" | \
        jq -r '[.[] | select(.tag_name | startswith("nightly-"))][0].tag_name // empty')
      if [ -z "$V0_VERSION" ]; then
        error "No nightly releases found"
      fi
      # Nightly tags are the full version (no 'v' prefix handling needed)
      DOWNLOAD_URL="${GITHUB_RELEASES}/download/${V0_VERSION}"
      TARBALL="v0-${V0_VERSION}.tar.gz"
      ;;
    stable|*)
      info "Fetching latest stable version..."
      V0_VERSION=$(curl -fsSL "${GITHUB_API}/repos/${V0_REPO}/releases/latest" | \
        jq -r '.tag_name' | sed 's/^v//')
      DOWNLOAD_URL="${GITHUB_RELEASES}/download/v${V0_VERSION}"
      TARBALL="v0-${V0_VERSION}.tar.gz"
      ;;
  esac
fi

# After installation, write channel marker
echo "${V0_CHANNEL}" > "${V0_INSTALL}/.channel"
```

**Usage**:
```bash
# Install latest stable (default)
curl -fsSL .../install.sh | bash

# Install latest nightly
curl -fsSL .../install.sh | V0_CHANNEL=nightly bash

# Install specific version
curl -fsSL .../install.sh | V0_VERSION=0.2.0 bash
```

**Verification**:
- Fresh install defaults to stable
- `V0_CHANNEL=nightly` installs nightly
- `.channel` file is written correctly

---

### Phase 6: Integration Testing & Documentation

**Goal**: Test end-to-end flows and update help text.

**Test scenarios**:
1. Fresh stable install → `v0 self version` shows stable
2. `v0 self update nightly` → switches to nightly
3. `v0 self update stable` → switches back to stable
4. `v0 self update 0.2.0` → installs specific version
5. `v0 self update --list` → shows available versions
6. `v0 self update --check` → shows what would change
7. Homebrew user runs update → gets helpful error message

**Unit tests to add** (`tests/unit/v0-self-update.bats`):
```bash
@test "v0 self update --help shows usage" {
  run v0 self update --help
  assert_success
  assert_output --partial "Update v0 installation"
}

@test "get_install_method detects direct install" {
  # Mock scenario
}

@test "v0 self update --check shows version comparison" {
  run v0 self update --check
  assert_success
  assert_output --partial "Current:"
}
```

**Documentation updates**:
- Update main help in `bin/v0` to mention `self update`
- Update README if one exists

---

## Key Implementation Details

### Version Resolution Logic

```
User Input          →  Resolved Version  →  Tag Name
─────────────────────────────────────────────────────
(none) or "stable"  →  0.2.1             →  v0.2.1
"nightly"           →  nightly-20260120  →  nightly-20260120-abc123
"0.2.0"             →  0.2.0             →  v0.2.0
"nightly-20260115"  →  nightly-20260115  →  nightly-20260115-xyz789
```

### Channel Tracking

The `.channel` file in the install directory tracks the user's preference:
- `stable` - User wants stable releases (default)
- `nightly` - User wants nightly builds
- `pinned:0.2.0` - User pinned to specific version

When running `v0 self update` without arguments, it uses the current channel.

### Atomic Update Process

```bash
1. Download to temp directory
2. Verify checksum
3. Create backup: mv ~/.local/share/v0 ~/.local/share/v0.bak
4. Extract new version
5. Verify new version runs: ~/.local/share/v0/bin/v0 --version
6. On success: rm -rf ~/.local/share/v0.bak
7. On failure: mv ~/.local/share/v0.bak ~/.local/share/v0
```

### Homebrew Detection

```bash
# Homebrew paths vary by architecture
# Intel: /usr/local/Cellar/, /usr/local/opt/
# ARM:   /opt/homebrew/Cellar/, /opt/homebrew/opt/

v0_path=$(command -v v0)
if [[ "${v0_path}" == *"/Cellar/"* ]] ||
   [[ "${v0_path}" == *"/homebrew/"* ]]; then
  # Homebrew managed
fi
```

---

## Verification Plan

### Phase 1 Verification
- [ ] `v0 self --help` shows new help with update command
- [ ] `v0 self debug --help` still works
- [ ] `v0 self-debug --help` backward compat works

### Phase 2 Verification
- [ ] `v0 self update --help` shows usage
- [ ] `v0 self update --list` queries GitHub and shows versions
- [ ] `v0 self update --check` shows comparison without installing

### Phase 3 Verification
- [ ] Manually trigger nightly workflow succeeds
- [ ] Nightly release has correct tag format
- [ ] Old nightlies are cleaned up

### Phase 4 Verification
- [ ] `v0 --version` reads from VERSION file
- [ ] `v0 self version` shows channel and install method
- [ ] `v0 self version --check` shows update availability

### Phase 5 Verification
- [ ] `V0_CHANNEL=nightly ./install.sh` works in test environment
- [ ] `.channel` file is created correctly

### Phase 6 Verification
- [ ] All test scenarios pass manually
- [ ] `make test` passes (new unit tests)
- [ ] `make lint` passes
