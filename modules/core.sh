#!/bin/bash
set -euo pipefail
##############################################################################
# ZZCOLLAB CORE MODULE - FOUNDATION INFRASTRUCTURE
##############################################################################
# 
# PURPOSE: Provides core infrastructure functions required by all other modules
#          This is the foundation module that must be loaded before others
#
# FEATURES:
#          - Unified logging system (log_info, log_error, log_success, log_warn)
#          - Module dependency validation system (require_module function)
#          - Package name validation and sanitization
#          - Item tracking system for manifest generation
#          - File safety utilities (safe_mkdir, safe_copy)
#          - Command availability caching
#          - Cross-platform compatibility helpers
#
# ARCHITECTURE: This module provides the basic building blocks that other
#               modules depend on. It establishes consistent patterns for
#               error handling, logging, and validation across the codebase.
#
# DEPENDENCIES: modules/constants.sh (optional, has fallbacks)
##############################################################################

#=============================================================================
# CORE CONSTANTS (from original zzcollab.sh)
#=============================================================================

# Load centralized constants if available, otherwise use local constants
if [[ "${ZZCOLLAB_CONSTANTS_LOADED:-}" == "true" ]]; then
    # Use centralized constants
    readonly AUTHOR_NAME="$ZZCOLLAB_AUTHOR_NAME"
    readonly AUTHOR_EMAIL="$ZZCOLLAB_AUTHOR_EMAIL"
    readonly AUTHOR_INSTITUTE="$ZZCOLLAB_AUTHOR_INSTITUTE"
    readonly AUTHOR_INSTITUTE_FULL="$ZZCOLLAB_AUTHOR_INSTITUTE_FULL"
    readonly JQ_AVAILABLE="$ZZCOLLAB_JQ_AVAILABLE"
else
    # Fallback to local constants
    readonly AUTHOR_NAME="${ZZCOLLAB_AUTHOR_NAME:-Your Name}"
    readonly AUTHOR_EMAIL="${ZZCOLLAB_AUTHOR_EMAIL:-your.email@example.com}"
    readonly AUTHOR_INSTITUTE="${ZZCOLLAB_INSTITUTE:-Your Institution}"
    readonly AUTHOR_INSTITUTE_FULL="${ZZCOLLAB_INSTITUTE_FULL:-Your Institution Full Name}"
    readonly JQ_AVAILABLE=$(command -v jq >/dev/null 2>&1 && echo "true" || echo "false")
fi

#=============================================================================
# LOGGING AND OUTPUT FUNCTIONS (extracted from lines 219-248)
#=============================================================================

# Verbosity levels:
#   0 = quiet (errors only)
#   1 = default (successes and errors) ~8 lines
#   2 = verbose (includes info messages) ~25 lines
#   3 = debug (everything) ~400 lines
export VERBOSITY_LEVEL="${VERBOSITY_LEVEL:-1}"

# Optional: Write all messages to log file regardless of verbosity
export LOG_FILE="${LOG_FILE:-.zzcollab.log}"
export ENABLE_LOG_FILE="${ENABLE_LOG_FILE:-false}"

##############################################################################
# FUNCTION: _write_to_log_file
# PURPOSE:  Write message to log file if enabled
# USAGE:    _write_to_log_file "level" "message"
##############################################################################
_write_to_log_file() {
    if [[ "$ENABLE_LOG_FILE" == "true" && -n "$LOG_FILE" ]]; then
        printf "[%s] %s: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE"
    fi
}

##############################################################################
# FUNCTION: log_debug
# PURPOSE:  Display detailed debug messages (only with -vv/--debug)
# USAGE:    log_debug "debug message"
# ARGS:
#   $* - Debug message text to display
# RETURNS:
#   0 - Always succeeds
# GLOBALS:
#   READ:  VERBOSITY_LEVEL
#   WRITE: None (outputs to stderr if VERBOSITY_LEVEL >= 3)
# EXAMPLE:
#   log_debug "Created directory: R"
#   log_debug "Loading module: core.sh"
##############################################################################
log_debug() {
    _write_to_log_file "DEBUG" "$*"
    if [[ $VERBOSITY_LEVEL -ge 3 ]]; then
        printf "🔍 %s\n" "$*" >&2
    fi
}

##############################################################################
# FUNCTION: log_info
# PURPOSE:  Display informational messages (shown with -v or higher)
# USAGE:    log_info "message text"
# ARGS:
#   $* - Message text to display
# RETURNS:
#   0 - Always succeeds
# GLOBALS:
#   READ:  VERBOSITY_LEVEL
#   WRITE: None (outputs to stderr if VERBOSITY_LEVEL >= 2)
# EXAMPLE:
#   log_info "Starting process..."
#   log_info "Found $count files"
##############################################################################
log_info() {
    _write_to_log_file "INFO" "$*"
    if [[ $VERBOSITY_LEVEL -ge 2 ]]; then
        printf "ℹ️  %s\n" "$*" >&2
    fi
}

##############################################################################
# FUNCTION: log_warn
# PURPOSE:  Display warning messages (shown at default level and higher)
# USAGE:    log_warn "warning message"
# ARGS:
#   $* - Warning message text to display
# RETURNS:
#   0 - Always succeeds
# GLOBALS:
#   READ:  VERBOSITY_LEVEL
#   WRITE: None (outputs to stderr if VERBOSITY_LEVEL >= 1)
# EXAMPLE:
#   log_warn "Configuration file not found, using defaults"
#   log_warn "Deprecated option used: $option"
##############################################################################
log_warn() {
    _write_to_log_file "WARN" "$*"
    if [[ $VERBOSITY_LEVEL -ge 1 ]]; then
        printf "⚠️  %s\n" "$*" >&2
    fi
}

##############################################################################
# FUNCTION: log_error
# PURPOSE:  Display error messages (always shown, even in quiet mode)
# USAGE:    log_error "error message"
# ARGS:
#   $* - Error message text to display
# RETURNS:
#   0 - Always succeeds
# GLOBALS:
#   READ:  None (always displays)
#   WRITE: None (outputs to stderr)
# EXAMPLE:
#   log_error "Failed to create directory: $dir"
#   log_error "Invalid argument: $arg"
##############################################################################
log_error() {
    _write_to_log_file "ERROR" "$*"
    # Errors always show, regardless of verbosity
    printf "❌ %s\n" "$*" >&2
}

##############################################################################
# FUNCTION: log_success
# PURPOSE:  Display success messages (shown at default level and higher)
# USAGE:    log_success "success message"
# ARGS:
#   $* - Success message text to display
# RETURNS:
#   0 - Always succeeds
# GLOBALS:
#   READ:  VERBOSITY_LEVEL
#   WRITE: None (outputs to stderr if VERBOSITY_LEVEL >= 1)
# EXAMPLE:
#   log_success "Package installed successfully"
#   log_success "Created $count files"
##############################################################################
log_success() {
    _write_to_log_file "SUCCESS" "$*"
    if [[ $VERBOSITY_LEVEL -ge 1 ]]; then
        printf "✅ %s\n" "$*" >&2
    fi
}

#=============================================================================
# PACKAGE NAME VALIDATION FUNCTIONS (extracted from lines 51-97)
#=============================================================================

##############################################################################
# FUNCTION: validate_package_name
# PURPOSE:  Converts current directory name into a valid R package name
# USAGE:    validate_package_name
# ARGS:     
#   None - Uses current working directory
# RETURNS:  
#   0 - Success, outputs valid package name to stdout
#   1 - Error, cannot create valid package name
# GLOBALS:  
#   READ:  PWD (current working directory)
#   WRITE: None
# EXAMPLE:
#   pkg_name=$(validate_package_name)
#   if validate_package_name >/dev/null; then
#       echo "Valid directory name"
#   fi
##############################################################################
validate_package_name() {
    local dir_name
    dir_name=$(basename "$(pwd)")
    
    local pkg_name
    # Clean directory name: keep only alphanumeric and periods, limit to 50 chars
    pkg_name=$(printf '%s' "$dir_name" | tr -cd '[:alnum:].' | head -c 50)
    
    # Check if cleaning resulted in empty string
    if [[ -z "$pkg_name" ]]; then
        echo "❌ Error: Cannot determine valid package name from directory '$dir_name'" >&2
        return 1
    fi
    
    # R packages must start with a letter
    if [[ ! "$pkg_name" =~ ^[[:alpha:]] ]]; then
        echo "❌ Error: Package name must start with a letter: '$pkg_name'" >&2
        return 1
    fi
    
    printf '%s' "$pkg_name"
}

#=============================================================================
# UTILITY FUNCTIONS (extracted from lines 335-384)
#=============================================================================

# Function: command_exists
# Purpose: Check if a command is available in the current PATH
# Usage: if command_exists docker; then ... fi
# Returns: 0 if command exists, 1 if not
command_exists() {
    # command -v is the POSIX-compliant way to check for command availability
    # It's more portable than 'which' and 'type'
    # Redirect both stdout and stderr to /dev/null to suppress output
    command -v "$1" >/dev/null 2>&1
}

#=============================================================================
# UNIFIED TRACKING SYSTEM
#=============================================================================

# Function: track_item
# Purpose: Universal tracking function for all manifest items
# Arguments: $1 - type (directory, file, template, symlink, docker_image)
#           $2 - primary data (path, file, template, etc.)
#           $3 - secondary data (for symlinks: target, templates: dest)
track_item() {
    local type="$1"
    local data1="$2"
    local data2="${3:-}"

    # Setup cleanup trap for temporary files
    local tmp=""
    cleanup_track_tmp() {
        if [[ -n "${tmp:-}" ]] && [[ -f "${tmp:-}" ]]; then
            rm -f "$tmp"
        fi
    }
    trap cleanup_track_tmp RETURN

    case "$type" in
        directory)
            if [[ "$JQ_AVAILABLE" == "true" ]] && [[ -f "${MANIFEST_FILE:-}" ]]; then
                tmp=$(mktemp)
                if jq --arg dir "$data1" '.directories += [$dir]' "${MANIFEST_FILE:-}" > "$tmp"; then
                    if ! mv "$tmp" "${MANIFEST_FILE:-}"; then
                        log_error "Failed to update manifest for directory: $data1"
                        return 1
                    fi
                else
                    log_error "jq failed to process manifest for directory: $data1"
                    return 1
                fi
            elif [[ -f "${MANIFEST_TXT:-}" ]]; then
                echo "directory:$data1" >> "${MANIFEST_TXT:-}" || {
                    log_error "Failed to append to text manifest for directory: $data1"
                    return 1
                }
            fi
            ;;
        file)
            if [[ "$JQ_AVAILABLE" == "true" ]] && [[ -f "${MANIFEST_FILE:-}" ]]; then
                tmp=$(mktemp)
                if jq --arg file "$data1" '.files += [$file]' "${MANIFEST_FILE:-}" > "$tmp"; then
                    if ! mv "$tmp" "${MANIFEST_FILE:-}"; then
                        log_error "Failed to update manifest for file: $data1"
                        return 1
                    fi
                else
                    log_error "jq failed to process manifest for file: $data1"
                    return 1
                fi
            elif [[ -f "${MANIFEST_TXT:-}" ]]; then
                echo "file:$data1" >> "${MANIFEST_TXT:-}" || {
                    log_error "Failed to append to text manifest for file: $data1"
                    return 1
                }
            fi
            ;;
        template)
            if [[ "$JQ_AVAILABLE" == "true" ]] && [[ -f "${MANIFEST_FILE:-}" ]]; then
                tmp=$(mktemp)
                if jq --arg template "$data1" --arg dest "$data2" '.template_files += [{"template": $template, "destination": $dest}]' "${MANIFEST_FILE:-}" > "$tmp"; then
                    if ! mv "$tmp" "${MANIFEST_FILE:-}"; then
                        log_error "Failed to update manifest for template: $data1 -> $data2"
                        return 1
                    fi
                else
                    log_error "jq failed to process manifest for template: $data1"
                    return 1
                fi
            elif [[ -f "${MANIFEST_TXT:-}" ]]; then
                echo "template:$data1:$data2" >> "${MANIFEST_TXT:-}" || {
                    log_error "Failed to append to text manifest for template: $data1"
                    return 1
                }
            fi
            ;;
        symlink)
            if [[ "$JQ_AVAILABLE" == "true" ]] && [[ -f "${MANIFEST_FILE:-}" ]]; then
                tmp=$(mktemp)
                if jq --arg link "$data1" --arg target "$data2" '.symlinks += [{"link": $link, "target": $target}]' "${MANIFEST_FILE:-}" > "$tmp"; then
                    if ! mv "$tmp" "${MANIFEST_FILE:-}"; then
                        log_error "Failed to update manifest for symlink: $data1 -> $data2"
                        return 1
                    fi
                else
                    log_error "jq failed to process manifest for symlink: $data1"
                    return 1
                fi
            elif [[ -f "${MANIFEST_TXT:-}" ]]; then
                echo "symlink:$data1:$data2" >> "${MANIFEST_TXT:-}" || {
                    log_error "Failed to append to text manifest for symlink: $data1"
                    return 1
                }
            fi
            ;;
        docker_image)
            if [[ "$JQ_AVAILABLE" == "true" ]] && [[ -f "${MANIFEST_FILE:-}" ]]; then
                tmp=$(mktemp)
                if jq --arg image "$data1" '.docker_image = $image' "${MANIFEST_FILE:-}" > "$tmp"; then
                    if ! mv "$tmp" "${MANIFEST_FILE:-}"; then
                        log_error "Failed to update manifest for docker_image: $data1"
                        return 1
                    fi
                else
                    log_error "jq failed to process manifest for docker_image: $data1"
                    return 1
                fi
            elif [[ -f "${MANIFEST_TXT:-}" ]]; then
                echo "docker_image:$data1" >> "${MANIFEST_TXT:-}" || {
                    log_error "Failed to append to text manifest for docker_image: $data1"
                    return 1
                }
            fi
            ;;
        *)
            log_error "Unknown tracking type: $type"
            return 1
            ;;
    esac
}

# Legacy wrapper functions for backward compatibility
track_directory() { track_item "directory" "$1"; }
track_file() { track_item "file" "$1"; }
track_template_file() { track_item "template" "$1" "${2:-}"; }
track_symlink() { track_item "symlink" "$1" "${2:-}"; }
track_docker_image() { track_item "docker_image" "$1"; }

#=============================================================================
# UNIFIED VALIDATION SYSTEM
#=============================================================================

# Function: validate_files_exist
# Purpose: Check that required files exist
# Arguments: $1 - description, $2+ - file paths
validate_files_exist() {
    local description="$1"
    shift
    local files=("$@")
    local missing_files=()
    
    for file in "${files[@]}"; do
        if [[ ! -f "$file" ]]; then
            missing_files+=("$file")
        fi
    done
    
    if [[ ${#missing_files[@]} -eq 0 ]]; then
        log_success "$description: all files exist"
        return 0
    else
        log_error "$description: missing files: ${missing_files[*]}"
        return 1
    fi
}

# Function: validate_directories_exist
# Purpose: Check that required directories exist
# Arguments: $1 - description, $2+ - directory paths
validate_directories_exist() {
    local description="$1"
    shift
    local directories=("$@")
    local missing_dirs=()
    
    for dir in "${directories[@]}"; do
        if [[ ! -d "$dir" ]]; then
            missing_dirs+=("$dir")
        fi
    done
    
    if [[ ${#missing_dirs[@]} -eq 0 ]]; then
        log_success "$description: all directories exist"
        return 0
    else
        log_error "$description: missing directories: ${missing_dirs[*]}"
        return 1
    fi
}

# Function: validate_commands_exist
# Purpose: Check that required commands are available
# Arguments: $1 - description, $2+ - command names
validate_commands_exist() {
    local description="$1"
    shift
    local commands=("$@")
    local missing_commands=()
    
    for cmd in "${commands[@]}"; do
        if ! command_exists "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -eq 0 ]]; then
        log_success "$description: all commands available"
        return 0
    else
        log_error "$description: missing commands: ${missing_commands[*]}"
        return 1
    fi
}

# Function: validate_with_callback
# Purpose: Generic validation with custom validation function
# Arguments: $1 - description, $2 - validation function, $3+ - arguments to validation function
validate_with_callback() {
    local description="$1"
    local validation_func="$2"
    shift 2
    
    log_info "Validating $description..."
    
    if "$validation_func" "$@"; then
        log_success "$description validation passed"
        return 0
    else
        log_error "$description validation failed"
        return 1
    fi
}

#=============================================================================
# MODULE DEPENDENCY VALIDATION
#=============================================================================

# Function: require_module
# Purpose: Unified module dependency validation system
#
# DESCRIPTION:
#   This function provides centralized dependency checking for all zzcollab modules.
#   It replaces 17 duplicate validation patterns that were scattered across modules,
#   providing consistent error handling and dependency management.
#
# ARCHITECTURE:
#   Each module sets a flag like "ZZCOLLAB_MODULENAME_LOADED=true" when it loads.
#   This function checks those flags to ensure dependencies are met before proceeding.
#   This prevents runtime errors from missing functions and provides clear error messages.
#
# ARGUMENTS:
#   $1+ - Module names to check (e.g., "core", "templates", "config")
#         Module names should be lowercase, matching the filename without .sh extension
#
# VALIDATION PROCESS:
#   1. Determines the calling module name from BASH_SOURCE stack
#   2. For each required module, checks if ZZCOLLAB_MODULENAME_LOADED=true
#   3. If any dependency is missing, shows clear error and exits
#   4. If all dependencies are satisfied, function returns normally
#
# USAGE EXAMPLES:
#   require_module "core"                    # Single dependency  
#   require_module "core" "templates"        # Multiple dependencies
#   require_module "constants" "core" "cli"  # Chain of dependencies
#
# ERROR BEHAVIOR:
#   - Exits with code 1 if any dependency is missing
#   - Provides clear error message showing which module needs which dependency
#   - Uses stderr for error output to avoid interfering with function returns
#
# BENEFITS:
#   - Eliminates 136+ lines of duplicate validation code
#   - Provides consistent error messages across all modules  
#   - Enables fail-fast behavior when dependencies are missing
#   - Makes module loading order explicit and enforceable
#
require_module() {
    # Extract the name of the calling module from the call stack
    # BASH_SOURCE[2] = script that called the function that called this function
    # This gives us the actual module doing the validation
    local current_module="${BASH_SOURCE[2]##*/}"  # Get filename only
    current_module="${current_module%.sh}"        # Remove .sh extension
    
    # Check each required module dependency
    for module in "$@"; do
        # Convert module name to uppercase for flag variable
        # Use tr command for compatibility across shell versions
        local module_upper=$(echo "$module" | tr '[:lower:]' '[:upper:]')
        
        # Construct the flag variable name (e.g., ZZCOLLAB_CORE_LOADED)
        local module_var="ZZCOLLAB_${module_upper}_LOADED"
        
        # Check if the required module has been loaded
        # ${!module_var:-} uses indirect variable expansion with default empty value
        if [[ "${!module_var:-}" != "true" ]]; then
            # Provide clear error message and exit
            # Use >&2 to send to stderr so it doesn't interfere with return values
            echo "❌ Error: ${current_module}.sh requires ${module}.sh to be loaded first" >&2
            exit 1
        fi
    done
}

# Function: confirm
# Purpose: Interactive confirmation prompt
# Arguments: $1 - prompt message (optional)
# Returns: 0 if user confirms (y/Y), 1 otherwise
confirm() {
    local prompt="${1:-Continue?}"
    read -p "$prompt [y/N] " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

#=============================================================================
# CORE MODULE VALIDATION
#=============================================================================

# Validate that this module is being sourced correctly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    log_error "core.sh should be sourced, not executed directly"
    exit 1
fi

# Set core module loaded flag
readonly ZZCOLLAB_CORE_LOADED=true