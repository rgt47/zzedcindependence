#!/bin/bash
set -euo pipefail
##############################################################################
# ZZCOLLAB UTILITIES MODULE (SIMPLIFIED)
##############################################################################
# 
# PURPOSE: Essential utility functions used across multiple modules
#          - Core file and directory operations with error handling
#          - Essential validation patterns
#          - System checks
#
# DEPENDENCIES: core.sh (logging, tracking)
#
# TRACKING: No file creation - pure utility functions
##############################################################################

# Validate required modules are loaded
require_module "core"

#=============================================================================
# CORE FILE AND DIRECTORY OPERATIONS
#=============================================================================

# Function: safe_mkdir
# Purpose: Create directory with error handling and logging
# Arguments: $1 - directory path, $2 - description (optional)
safe_mkdir() {
    local dir="$1"
    local description="${2:-directory}"
    
    if mkdir -p "$dir" 2>/dev/null; then
        log_info "Created $description: $dir"
        track_directory "$dir"
        return 0
    else
        log_error "Failed to create $description: $dir"
        return 1
    fi
}

# Function: safe_copy
# Purpose: Copy file with error handling and logging
# Arguments: $1 - source, $2 - destination, $3 - description (optional)
safe_copy() {
    local src="$1"
    local dest="$2"
    local description="${3:-file}"
    
    if cp "$src" "$dest" 2>/dev/null; then
        log_info "Copied $description: $src → $dest"
        track_file "$dest"
        return 0
    else
        log_error "Failed to copy $description: $src → $dest"
        return 1
    fi
}

# Function: safe_symlink - REMOVED (unused)
# All symlink operations use direct ln -sf commands
# Removed to eliminate dead code (0 calls found)

#=============================================================================
# ESSENTIAL VALIDATION FUNCTIONS - REMOVED (unused)
#=============================================================================
# The following functions were removed as they had 0 calls:
# - file_exists_and_readable() - Direct [[ -f && -r ]] tests used instead
# - dir_exists_and_writable() - Direct [[ -d && -w ]] tests used instead
# - is_valid_identifier() - Validation done inline where needed

#=============================================================================
# ESSENTIAL SYSTEM UTILITIES - REMOVED (unused)
#=============================================================================
# The following functions were removed as they had 0 calls:
# - is_docker_available() - Direct docker checks used instead
# - is_git_repo() - Direct git rev-parse checks used instead

#=============================================================================
# MODULE VALIDATION
#=============================================================================

# Validate that this module is being sourced correctly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "❌ Error: utils.sh should be sourced, not executed directly" >&2
    exit 1
fi

# Set utils module loaded flag
readonly ZZCOLLAB_UTILS_LOADED=true
