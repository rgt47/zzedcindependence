#!/bin/bash
set -euo pipefail
##############################################################################
# ZZCOLLAB CONSTANTS MODULE
##############################################################################
# 
# PURPOSE: Centralized global constants and environment variables
#          - Color constants for output formatting
#          - Path constants for script directories
#          - Manifest and configuration file names
#          - Default values and system constants
#
# DEPENDENCIES: None (this is a foundation module)
##############################################################################

#=============================================================================
# COLOR CONSTANTS (ANSI escape codes for terminal output formatting)
#=============================================================================

# These ANSI escape sequences provide colored terminal output
# Used throughout zzcollab for consistent visual feedback to users
# ANSI format: \033[<style>;<color>m where style 0=normal, 1=bold

readonly RED='\033[0;31m'      # Red text - used for errors and failures
readonly GREEN='\033[0;32m'    # Green text - used for success messages
readonly YELLOW='\033[1;33m'   # Bold yellow text - used for warnings
readonly BLUE='\033[0;34m'     # Blue text - used for information messages
readonly NC='\033[0m'          # No Color - resets terminal to default

#=============================================================================
# PATH CONSTANTS (computed once for efficiency)
#=============================================================================

# Main zzcollab script directory
# ${BASH_SOURCE[1]} refers to the calling script (not this constants file)
# This allows modules to find the main zzcollab directory regardless of
# where they are called from
readonly ZZCOLLAB_SCRIPT_DIR="/Users/zenn/bin/zzcollab-support"
# Derived directories - built from main script directory
readonly ZZCOLLAB_TEMPLATES_DIR="$ZZCOLLAB_SCRIPT_DIR/templates"    # Template files location
readonly ZZCOLLAB_MODULES_DIR="$ZZCOLLAB_SCRIPT_DIR/modules"        # Shell modules location

#=============================================================================
# MANIFEST AND CONFIGURATION FILES (for project tracking and user settings)
#=============================================================================

# Manifest files track all files created during zzcollab setup
# These enable clean uninstallation and prevent conflicts
readonly ZZCOLLAB_MANIFEST_JSON=".zzcollab/manifest.json"  # Machine-readable manifest
readonly ZZCOLLAB_MANIFEST_TXT=".zzcollab/manifest.txt"    # Human-readable manifest

# Configuration file hierarchy (loaded in priority order)
# Project-level config overrides user-level, which overrides system-level
readonly ZZCOLLAB_CONFIG_PROJECT="./zzcollab.yaml"                  # Project-specific settings
readonly ZZCOLLAB_CONFIG_USER_DIR="$HOME/.zzcollab"                 # User config directory
readonly ZZCOLLAB_CONFIG_USER="$ZZCOLLAB_CONFIG_USER_DIR/config.yaml"  # User-level settings
readonly ZZCOLLAB_CONFIG_SYSTEM="/etc/zzcollab/config.yaml"         # System-wide settings

#=============================================================================
# DEFAULT VALUES
#=============================================================================

# Docker and build defaults
readonly ZZCOLLAB_DEFAULT_BASE_IMAGE="rocker/r-ver"
readonly ZZCOLLAB_DEFAULT_INIT_BASE_IMAGE="r-ver"
readonly ZZCOLLAB_DEFAULT_PROFILE_NAME="ubuntu_standard_minimal"

# Author information (should be set via environment variables or config file)
readonly ZZCOLLAB_AUTHOR_NAME="${ZZCOLLAB_AUTHOR_NAME:-Your Name}"
readonly ZZCOLLAB_AUTHOR_EMAIL="${ZZCOLLAB_AUTHOR_EMAIL:-your.email@example.com}"
readonly ZZCOLLAB_AUTHOR_INSTITUTE="${ZZCOLLAB_INSTITUTE:-Your Institution}"
readonly ZZCOLLAB_AUTHOR_INSTITUTE_FULL="${ZZCOLLAB_INSTITUTE_FULL:-Your Institution Full Name}"

#=============================================================================
# SYSTEM CONSTANTS
#=============================================================================

# Command availability checks (cached for performance)
readonly ZZCOLLAB_JQ_AVAILABLE=$(command -v jq >/dev/null 2>&1 && echo "true" || echo "false")

# Script metadata
readonly ZZCOLLAB_SCRIPT_NAME="$(basename "${BASH_SOURCE[1]}")"
readonly ZZCOLLAB_TODAY="$(date '+%B %d, %Y')"

#=============================================================================
# EXIT CODE CONSTANTS (LOW severity Issue #16 fix)
#=============================================================================

# Standard exit codes for consistent error handling across all modules
# Using named constants instead of magic numbers improves code readability
# and makes error handling more maintainable

readonly EXIT_SUCCESS=0        # Successful execution
readonly EXIT_ERROR=1          # General error
readonly EXIT_USAGE=2          # Usage error (invalid arguments)
readonly EXIT_CONFIG=3         # Configuration error
readonly EXIT_NOTFOUND=4       # Required file or resource not found
readonly EXIT_PERMISSION=5     # Permission denied
readonly EXIT_VALIDATION=6     # Validation failed
readonly EXIT_DOCKER=7         # Docker-related error
readonly EXIT_NETWORK=8        # Network error
readonly EXIT_INTERRUPT=130    # User interrupted (Ctrl+C)

#=============================================================================
# MODULE LOADING FLAGS
#=============================================================================

# Module loading status flags (set by each module when loaded)
# These are set by individual modules, declared here for reference
# readonly ZZCOLLAB_CORE_LOADED=true          # Set by core.sh
# readonly ZZCOLLAB_TEMPLATES_LOADED=true     # Set by templates.sh
# readonly ZZCOLLAB_CLI_LOADED=true           # Set by cli.sh
# readonly ZZCOLLAB_CONFIG_LOADED=true        # Set by config.sh
# readonly ZZCOLLAB_ANALYSIS_LOADED=true      # Set by analysis.sh
# readonly ZZCOLLAB_GITHUB_LOADED=true        # Set by github.sh

#=============================================================================
# CONSTANTS MODULE VALIDATION
#=============================================================================

# Validate that this module is being sourced correctly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "❌ Error: constants.sh should be sourced, not executed directly" >&2
    exit 1
fi

# Set constants module loaded flag
readonly ZZCOLLAB_CONSTANTS_LOADED=true