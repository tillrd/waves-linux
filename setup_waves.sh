#!/bin/bash
# Waves Plugins Linux Setup Script
# This script helps copy Waves plugins from Windows to Linux Wine environment
# Requires: Wine, yabridge, and access to Windows installation with Waves

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script version
VERSION="1.0.0"

# Default values
WINE_PREFIX="${WINEPREFIX:-$HOME/.wine}"
SKIP_CHECKS=false
DRY_RUN=false
VERBOSE=false

# Function to print colored messages
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to show usage
show_usage() {
    cat << EOF
Waves Linux Setup Script v${VERSION}

Usage: $0 [OPTIONS] <WINDOWS_PATH>

Arguments:
  WINDOWS_PATH    Path to Windows installation (e.g., /mnt/windows, /media/user/DRIVE)

Options:
  -h, --help         Show this help message
  -v, --verbose     Verbose output
  -d, --dry-run     Show what would be done without making changes
  -s, --skip-checks Skip prerequisite checks
  -w, --wine-prefix Set Wine prefix (default: ~/.wine)
  --version         Show version information

Examples:
  $0 /mnt/windows
  $0 /media/user/Windows --verbose
  $0 /mnt/windows --dry-run
  $0 --wine-prefix ~/.wine-custom /mnt/windows

Requirements:
  - Wine installed and configured
  - yabridge installed
  - Access to Windows drive with Waves plugins installed
  - Sufficient disk space (~11GB for full Waves installation)

EOF
}

# Function to check prerequisites
check_prerequisites() {
    info "Checking prerequisites..."
    local errors=0

    # Check Wine
    if ! command -v wine &> /dev/null; then
        error "Wine is not installed or not in PATH"
        echo "  Install with: sudo apt install wine (or your distro's package manager)"
        ((errors++))
    else
        local wine_version=$(wine --version 2>&1 || echo "unknown")
        success "Wine found: $wine_version"
    fi

    # Check winetricks
    if ! command -v winetricks &> /dev/null; then
        warning "winetricks not found (optional but recommended)"
    else
        success "winetricks found"
    fi

    # Check yabridge
    if ! command -v yabridgectl &> /dev/null; then
        error "yabridgectl is not installed or not in PATH"
        echo "  Install from: https://github.com/robbert-vdh/yabridge"
        ((errors++))
    else
        local yabridge_version=$(yabridgectl --version 2>&1 || echo "unknown")
        success "yabridgectl found: $yabridge_version"
    fi

    # Check Wine prefix
    if [ ! -d "$WINE_PREFIX" ]; then
        warning "Wine prefix not found: $WINE_PREFIX"
        echo "  Run 'winecfg' first to initialize Wine, or specify a different prefix with --wine-prefix"
        read -p "  Create Wine prefix now? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            info "Initializing Wine prefix..."
            WINEPREFIX="$WINE_PREFIX" winecfg 2>&1 | grep -v "wine: created" || true
            success "Wine prefix initialized"
        else
            ((errors++))
        fi
    else
        success "Wine prefix found: $WINE_PREFIX"
    fi

    # Check disk space
    local available_space=$(df -BG "$WINE_PREFIX" | tail -1 | awk '{print $4}' | sed 's/G//')
    if [ "$available_space" -lt 15 ]; then
        warning "Low disk space: ${available_space}GB available (recommended: 15GB+)"
        read -p "  Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            ((errors++))
        fi
    else
        success "Disk space OK: ${available_space}GB available"
    fi

    if [ $errors -gt 0 ]; then
        error "Prerequisites check failed. Please fix the issues above."
        return 1
    fi

    success "All prerequisites met!"
    return 0
}

# Function to detect Windows username
detect_windows_user() {
    local windows_path="$1"
    local win_user=""

    info "Detecting Windows username..."

    # Try common usernames first
    for user in "$USER" "User" "Administrator"; do
        if [ -d "$windows_path/Users/$user" ]; then
            win_user="$user"
            success "Found Windows user: $win_user"
            echo "$win_user"
            return 0
        fi
    done

    # Auto-detect from Users directory
    if [ -d "$windows_path/Users" ]; then
        for user_dir in "$windows_path/Users"/*; do
            if [ -d "$user_dir" ]; then
                local user_name=$(basename "$user_dir")
                # Skip default Windows directories
                if [[ ! "$user_name" =~ ^(Public|Default|All Users|Default User|desktop.ini)$ ]]; then
                    win_user="$user_name"
                    success "Auto-detected Windows user: $win_user"
                    echo "$win_user"
                    return 0
                fi
            fi
        done
    fi

    # Fallback: ask user
    error "Could not auto-detect Windows username"
    echo "Available users in $windows_path/Users:"
    ls -1 "$windows_path/Users" 2>/dev/null | grep -v -E "^(Public|Default|All Users|Default User|desktop.ini)$" || echo "  (none found)"
    read -p "Enter Windows username: " win_user

    if [ -d "$windows_path/Users/$win_user" ]; then
        success "Using Windows user: $win_user"
        echo "$win_user"
        return 0
    else
        error "Invalid username or path not found: $windows_path/Users/$win_user"
        return 1
    fi
}

# Function to check if file/directory exists on Windows
check_windows_path() {
    local path="$1"
    local description="$2"

    if [ -e "$path" ]; then
        if [ "$VERBOSE" = true ]; then
            info "Found: $description"
        fi
        return 0
    else
        if [ "$VERBOSE" = true ]; then
            warning "Not found: $description ($path)"
        fi
        return 1
    fi
}

# Function to copy with error handling
safe_copy() {
    local src="$1"
    local dst="$2"
    local description="$3"

    if [ "$DRY_RUN" = true ]; then
        info "[DRY RUN] Would copy: $description"
        info "  From: $src"
        info "  To: $dst"
        return 0
    fi

    if [ ! -e "$src" ]; then
        warning "Source not found, skipping: $description"
        return 1
    fi

    info "Copying: $description"
    if [ "$VERBOSE" = true ]; then
        info "  From: $src"
        info "  To: $dst"
    fi

    # Create destination directory
    mkdir -p "$(dirname "$dst")" 2>/dev/null || {
        error "Failed to create directory: $(dirname "$dst")"
        return 1
    }

    # Copy with progress if available
    if command -v rsync &> /dev/null && [ -d "$src" ]; then
        rsync -av --progress "$src" "$dst" 2>&1 | tail -1 || {
            error "Failed to copy: $description"
            return 1
        }
    else
        cp -rv "$src" "$dst" 2>&1 | tail -1 || {
            error "Failed to copy: $description"
            return 1
        }
    fi

    success "Copied: $description"
    return 0
}

# Function to verify Windows path
verify_windows_path() {
    local windows_path="$1"

    info "Verifying Windows installation path..."

    # Check if path exists
    if [ ! -d "$windows_path" ]; then
        error "Windows path does not exist: $windows_path"
        echo ""
        echo "Common mount points:"
        echo "  /mnt/windows"
        echo "  /media/\$USER/DRIVE_LABEL"
        echo "  /run/media/\$USER/DRIVE_LABEL"
        echo ""
        echo "To mount a Windows drive:"
        echo "  sudo mkdir -p /mnt/windows"
        echo "  sudo mount -t ntfs3 /dev/sdXY /mnt/windows"
        return 1
    fi

    # Check for Windows directory structure
    local checks_passed=0
    local total_checks=0

    ((total_checks++))
    if check_windows_path "$windows_path/Program Files" "Program Files"; then
        ((checks_passed++))
    fi

    ((total_checks++))
    if check_windows_path "$windows_path/Users" "Users directory"; then
        ((checks_passed++))
    fi

    ((total_checks++))
    if check_windows_path "$windows_path/ProgramData" "ProgramData"; then
        ((checks_passed++))
    fi

    if [ $checks_passed -lt 2 ]; then
        error "Path doesn't appear to be a Windows installation"
        echo "  Found $checks_passed/$total_checks Windows directories"
        echo "  Expected: Program Files, Users, ProgramData"
        return 1
    fi

    success "Windows installation verified ($checks_passed/$total_checks checks passed)"
    return 0
}

# Main copy function
copy_waves_files() {
    local windows_path="$1"
    local win_user="$2"
    local linux_user="${USER:-$(whoami)}"
    local copied=0
    local skipped=0

    info "Starting Waves files copy operation..."
    echo ""

    # Define copy operations
    declare -a copy_ops=(
        "$windows_path/Program Files/Waves Central|$WINE_PREFIX/drive_c/Program Files/Waves Central|Waves Central"
        "$windows_path/Program Files (x86)/Waves|$WINE_PREFIX/drive_c/Program Files (x86)/Waves|Waves plugins and data"
        "$windows_path/ProgramData/Waves Audio|$WINE_PREFIX/drive_c/ProgramData/Waves Audio|Waves ProgramData"
        "$windows_path/Users/$win_user/AppData/Local/Waves Audio|$WINE_PREFIX/drive_c/users/$linux_user/AppData/Local/Waves Audio|Waves AppData Local"
        "$windows_path/Users/$win_user/AppData/Roaming/Waves Audio|$WINE_PREFIX/drive_c/users/$linux_user/AppData/Roaming/Waves Audio|Waves AppData Roaming"
        "$windows_path/Users/Public/Waves Audio|$WINE_PREFIX/drive_c/users/Public/Waves Audio|Waves Public data"
        "$windows_path/Program Files/Common Files/VST3/WaveShell*.vst3|$WINE_PREFIX/drive_c/Program Files/Common Files/VST3|VST3 WaveShell plugins"
        "$windows_path/Program Files/VSTPlugIns/WaveShell*.dll|$WINE_PREFIX/drive_c/Program Files/VSTPlugins|VST2 WaveShell plugins"
    )

    # Execute copy operations
    for operation in "${copy_ops[@]}"; do
        IFS='|' read -r src dst desc <<< "$operation"
        
        # Handle wildcards
        if [[ "$src" == *"*"* ]]; then
            # For wildcard patterns, copy each match
            local pattern="${src%%|*}"
            local base_src="${pattern%/*}"
            local file_pattern="${pattern##*/}"
            
            if [ -d "$base_src" ]; then
                for file in "$base_src"/$file_pattern; do
                    if [ -e "$file" ]; then
                        local filename=$(basename "$file")
                        safe_copy "$file" "$dst/$filename" "$desc: $filename" && ((copied++)) || ((skipped++))
                    fi
                done
            else
                warning "Source directory not found: $base_src (skipping $desc)"
                ((skipped++))
            fi
        else
            # Regular directory/file copy
            safe_copy "$src" "$dst" "$desc" && ((copied++)) || ((skipped++))
        fi
    done

    echo ""
    success "Copy operation complete!"
    info "  Copied: $copied items"
    if [ $skipped -gt 0 ]; then
        warning "  Skipped: $skipped items (not found or failed)"
    fi
}

# Function to sync with yabridge
sync_yabridge() {
    info "Syncing plugins with yabridge..."

    if [ "$DRY_RUN" = true ]; then
        info "[DRY RUN] Would run: yabridgectl sync"
        return 0
    fi

    if ! yabridgectl sync; then
        error "yabridgectl sync failed"
        warning "You may need to run 'yabridgectl sync' manually later"
        return 1
    fi

    success "Plugins synced with yabridge"
    
    # Show Waves plugins
    info "Waves plugins found:"
    yabridgectl status 2>/dev/null | grep -i waves || warning "No Waves plugins detected (they may need activation)"
}

# Function to show next steps
show_next_steps() {
    cat << EOF

${GREEN}=== Setup Complete! ===${NC}

Next steps:

1. ${BLUE}Start Waves Local Server${NC} (if needed):
   cd "$WINE_PREFIX/drive_c/ProgramData/Waves Audio/WavesLocalServer/WavesLocalServer.bundle/Contents/Win64"
   WINEPREFIX="$WINE_PREFIX" wine WavesLocalServer.exe &

2. ${BLUE}Run Waves Central${NC} (for activation):
   cd "$WINE_PREFIX/drive_c/Program Files/Waves Central"
   WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all DISPLAY=:0 wine "Waves Central.exe" &

3. ${BLUE}Test plugins in your DAW${NC}:
   - Open your DAW (Reaper, Ardour, etc.)
   - Rescan plugins
   - Look for "WaveShell" entries
   - Load and test a Waves plugin

4. ${BLUE}If plugins need activation${NC}:
   - Log into Waves Central
   - Go to "Licenses" tab
   - Activate plugins to "Windows 10" (not USB)

${YELLOW}Note:${NC} If you copied from Windows, plugins may already be activated!

For detailed instructions, see: WAVES_LINUX_SETUP.md

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -s|--skip-checks)
                SKIP_CHECKS=true
                shift
                ;;
            -w|--wine-prefix)
                WINE_PREFIX="$2"
                shift 2
                ;;
            --version)
                echo "Waves Linux Setup Script v${VERSION}"
                exit 0
                ;;
            -*)
                error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [ -z "${WINDOWS_PATH:-}" ]; then
                    WINDOWS_PATH="$1"
                else
                    error "Multiple Windows paths specified"
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [ -z "${WINDOWS_PATH:-}" ]; then
        error "Windows path is required"
        show_usage
        exit 1
    fi
}

# Main function
main() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║     Waves Plugins Linux Setup Script v${VERSION}          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""

    # Parse arguments
    parse_args "$@"

    # Export Wine prefix
    export WINEPREFIX="$WINE_PREFIX"

    # Run checks unless skipped
    if [ "$SKIP_CHECKS" = false ]; then
        if ! check_prerequisites; then
            error "Prerequisites check failed. Use --skip-checks to continue anyway."
            exit 1
        fi
        echo ""
    else
        warning "Skipping prerequisite checks (--skip-checks)"
    fi

    # Verify Windows path
    if ! verify_windows_path "$WINDOWS_PATH"; then
        exit 1
    fi
    echo ""

    # Detect Windows user
    WIN_USER=$(detect_windows_user "$WINDOWS_PATH")
    if [ -z "$WIN_USER" ]; then
        exit 1
    fi
    echo ""

    # Copy files
    copy_waves_files "$WINDOWS_PATH" "$WIN_USER"
    echo ""

    # Sync with yabridge
    if [ "$DRY_RUN" = false ]; then
        sync_yabridge
        echo ""
    fi

    # Show next steps
    if [ "$DRY_RUN" = false ]; then
        show_next_steps
    else
        info "Dry run complete. Run without --dry-run to perform actual copy."
    fi
}

# Run main function
main "$@"
