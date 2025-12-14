#!/usr/bin/env bash
set -euo pipefail
# modules/validation.sh - Package dependency validation (pure shell, no R required)
#
# This module validates that all R packages used in code are properly declared
# in DESCRIPTION and locked in renv.lock for reproducibility.
#
# Key Innovation: Runs on host without requiring R installation
# - Package extraction: pure shell (grep, sed, awk)
# - DESCRIPTION parsing: pure shell (awk)
# - renv.lock parsing: jq (standard JSON tool)
# - CRAN validation: curl (HTTP API)

# Source dependencies (core.sh must be first - provides require_module)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/core.sh"
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/constants.sh"

#==============================================================================
# CONFIGURATION
#==============================================================================

# Base R packages that don't need declaration
BASE_PACKAGES=(
    "base" "utils" "stats" "graphics" "grDevices"
    "methods" "datasets" "tools" "grid" "parallel"
)

# Placeholder/invalid package names to exclude from validation
PLACEHOLDER_PACKAGES=(
    "package" "pkg" "mypackage" "myproject" "yourpackage"
    "project" "data" "result" "output" "input"
    "test" "example" "sample" "demo" "template"
    "local" "any" "all" "none" "NULL"
    "foo" "bar" "baz" "qux"
    "zzcollab"  # Don't declare ourselves as a dependency
)

# Cache the current package name once (avoid redundant file reads)
readonly CURRENT_PACKAGE="${CURRENT_PACKAGE:-$(grep '^Package:' DESCRIPTION 2>/dev/null | sed 's/^Package:[[:space:]]*//' || echo '')}"

# Add current package to placeholders (don't self-reference)
if [[ -n "$CURRENT_PACKAGE" ]]; then
    PLACEHOLDER_PACKAGES+=("$CURRENT_PACKAGE")
fi

#==============================================================================
# HELPER FUNCTIONS
#==============================================================================

##############################################################################
# Function: verify_description_file
# Purpose: Verify DESCRIPTION file exists and is writable
# Args:
#   $1 (optional): desc_file - Path to DESCRIPTION file (default: DESCRIPTION)
#   $2 (optional): require_write - true/false (default: false)
# Returns: 0 if valid, 1 if missing or not writable
# Globals: None
##############################################################################
verify_description_file() {
    local desc_file="${1:-DESCRIPTION}"
    local require_write="${2:-false}"

    if [[ ! -f "$desc_file" ]]; then
        log_error "❌ DESCRIPTION file not found: $desc_file"
        log_error ""
        log_error "DESCRIPTION is required for R package metadata and dependency tracking."
        log_error "It lists all packages your project depends on (in the Imports field)."
        log_error ""
        log_error "Create one with:"
        log_error "  printf 'Package: myproject\\nVersion: 0.1.0\\nTitle: My Project\\n' > DESCRIPTION"
        log_error ""
        log_error "Or copy the template:"
        log_error "  cp templates/DESCRIPTION_template DESCRIPTION"
        log_error ""
        log_error "See: docs/SETUP_DOCUMENTATION_SYSTEM.md for complete template"
        return 1
    fi

    if [[ "$require_write" == "true" ]] && [[ ! -w "$desc_file" ]]; then
        log_error "❌ DESCRIPTION file not writable: $desc_file"
        log_error ""
        log_error "The DESCRIPTION file at '$desc_file' cannot be modified."
        log_error ""
        log_error "Recovery steps:"
        log_error "  1. Check file permissions: ls -la $desc_file"
        log_error "  2. Make writable: chmod u+w $desc_file"
        log_error "  3. Verify your user owns it: chown \$USER $desc_file"
        log_error ""
        log_error "If file is owned by another user, ask them to add you write permission:"
        log_error "  chmod g+w $desc_file  # for group write"
        return 1
    fi

    return 0
}

# Directories to scan for R code
STANDARD_DIRS=("." "R" "scripts" "analysis")
STRICT_DIRS=("." "R" "scripts" "analysis" "tests" "vignettes" "inst")

# Files to skip (documentation examples, templates, infrastructure)
SKIP_FILES=(
    "*/README.Rmd"
    "*/README.md"
    "*/CLAUDE.md"
    "*/examples/*"
    "*/inst/examples/*"
    "*/man/examples/*"
    "*/renv/*"
    "*/.cache/*"
    "*/.git/*"
)

# File extensions to search
FILE_EXTENSIONS=("R" "Rmd" "qmd" "Rnw")

#==============================================================================
# HELPER FUNCTIONS
#==============================================================================

#-----------------------------------------------------------------------------
# FUNCTION: format_r_package_vector
# PURPOSE:  Format package array as R vector string c("pkg1", "pkg2", ...)
# ARGS:     $@ - Package names
# OUTPUTS:  R vector string to stdout
#-----------------------------------------------------------------------------
format_r_package_vector() {
    local packages=("$@")
    local count=${#packages[@]}

    if [[ $count -eq 0 ]]; then
        echo "c()"
        return
    elif [[ $count -eq 1 ]]; then
        echo "c(\"${packages[0]}\")"
        return
    else
        local result="c("
        for i in "${!packages[@]}"; do
            if [[ $i -eq 0 ]]; then
                result+="\"${packages[i]}\""
            else
                result+=", \"${packages[i]}\""
            fi
        done
        result+=")"
        echo "$result"
    fi
}

#-----------------------------------------------------------------------------
# FUNCTION: fetch_cran_package_info
# PURPOSE:  Fetch package metadata from CRAN API
# ARGS:     $1 - Package name
# OUTPUTS:  JSON with package info to stdout
# RETURNS:  0 on success, 1 on failure
#-----------------------------------------------------------------------------
fetch_cran_package_info() {
    local pkg="$1"
    local cran_url="https://crandb.r-pkg.org/${pkg}"

    local response
    response=$(curl -s -f "$cran_url" 2>/dev/null)
    local curl_exit=$?

    if [[ $curl_exit -ne 0 ]] || [[ -z "$response" ]]; then
        return 1
    fi

    echo "$response"
    return 0
}

#-----------------------------------------------------------------------------
# FUNCTION: validate_package_on_cran
# PURPOSE:  Check if a package exists on CRAN (upfront validation)
# DESCRIPTION:
#   Validates that a package name exists on CRAN before attempting to
#   add it to renv.lock. This prevents false positives from non-CRAN
#   packages (local, GitHub, Bioconductor) that should be skipped.
#   Returns 0 if package is on CRAN, 1 if not found or network error.
# ARGS:     $1 - Package name
# RETURNS:  0 if package exists on CRAN
#           1 if package not on CRAN or not reachable
# SIDE EFFECTS: None
#-----------------------------------------------------------------------------
validate_package_on_cran() {
    local pkg="$1"

    # Use fetch_cran_package_info to check existence
    if fetch_cran_package_info "$pkg" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

#-----------------------------------------------------------------------------
# FUNCTION: validate_package_on_bioconductor
# PURPOSE:  Check if a package exists on Bioconductor
# DESCRIPTION:
#   Validates that a package exists on Bioconductor registry.
#   Bioconductor is a major source for bioinformatics R packages.
#   Uses the Bioconductor JSON API for validation.
# ARGS:     $1 - Package name
# RETURNS:  0 if package exists on Bioconductor
#           1 if package not found or not reachable
#-----------------------------------------------------------------------------
validate_package_on_bioconductor() {
    local pkg="$1"
    local bioc_url="https://www.bioconductor.org/packages/json/3.17/${pkg}"

    local response
    response=$(curl -s -f "$bioc_url" 2>/dev/null)
    local curl_exit=$?

    if [[ $curl_exit -eq 0 ]] && [[ -n "$response" ]]; then
        return 0
    else
        return 1
    fi
}

#-----------------------------------------------------------------------------
# FUNCTION: validate_package_on_github
# PURPOSE:  Check if a package exists on GitHub
# DESCRIPTION:
#   Validates that a GitHub package reference is valid.
#   Accepts format: username/repo
#   Uses GitHub API to verify repository exists.
#   Note: Doesn't require authentication for basic checks.
# ARGS:     $1 - Package reference (username/repo format)
# RETURNS:  0 if repository exists on GitHub
#           1 if not found or invalid format
#-----------------------------------------------------------------------------
validate_package_on_github() {
    local pkg="$1"

    # Check if it looks like a GitHub reference (contains /)
    if [[ ! "$pkg" =~ "/" ]]; then
        return 1
    fi

    local github_url="https://api.github.com/repos/${pkg}"

    local response
    response=$(curl -s -f "$github_url" 2>/dev/null)
    local curl_exit=$?

    if [[ $curl_exit -eq 0 ]] && [[ -n "$response" ]] && [[ ! "$response" =~ "Not Found" ]]; then
        return 0
    else
        return 1
    fi
}

#-----------------------------------------------------------------------------
# FUNCTION: is_installable_package
# PURPOSE:  Check if a package is installable from standard repositories
# DESCRIPTION:
#   Comprehensive validation that checks multiple package sources:
#   1. CRAN (most common)
#   2. Bioconductor (bioinformatics packages)
#   3. GitHub (username/repo format)
#
#   Returns 0 if package is found in ANY of these sources.
#   Returns 1 if package not found in any source (likely local/non-standard).
#
#   This prevents false positives from non-installable packages.
# ARGS:     $1 - Package name or reference
# RETURNS:  0 if installable from standard source
#           1 if not found in any standard source
# SIDE EFFECTS: None
#-----------------------------------------------------------------------------
is_installable_package() {
    local pkg="$1"

    # Try CRAN first (fastest, most common)
    if validate_package_on_cran "$pkg"; then
        log_debug "  ✅ $pkg (found on CRAN)"
        return 0
    fi

    # Try Bioconductor
    if validate_package_on_bioconductor "$pkg"; then
        log_debug "  ✅ $pkg (found on Bioconductor)"
        return 0
    fi

    # Try GitHub (must be username/repo format)
    if validate_package_on_github "$pkg"; then
        log_debug "  ✅ $pkg (found on GitHub)"
        return 0
    fi

    # Not found in any standard source
    log_debug "  ❌ $pkg (not in CRAN/Bioconductor/GitHub)"
    return 1
}

#-----------------------------------------------------------------------------
# FUNCTION: add_package_to_description
# PURPOSE:  Add package to DESCRIPTION Imports field using pure shell tools
# ARGS:     $1 - Package name
# RETURNS:  0 on success, 1 on failure
# DESCRIPTION:
#   Adds package to Imports field in DESCRIPTION file using awk.
#   Handles existing Imports field and maintains proper formatting.
#-----------------------------------------------------------------------------
add_package_to_description() {
    local pkg="$1"
    local desc_file="DESCRIPTION"

    # Verify file exists and is writable
    verify_description_file "$desc_file" true || return 1

    log_debug "Adding $pkg to DESCRIPTION Imports..."

    # Create backup
    local temp_desc
    temp_desc=$(mktemp)
    cp "$desc_file" "$temp_desc"

    # Use awk to add package to Imports field
    # Handles three cases:
    # 1. Imports field exists in middle of file - append to it
    # 2. Imports field exists at end of file - append to it
    # 3. No Imports field exists - create new one at EOF
    awk -v pkg="$pkg" '
    BEGIN {
        in_imports = 0
        added = 0
        found_imports_field = 0  # Track if Imports: field exists at all
    }

    # Detect Imports field start
    /^Imports:/ {
        found_imports_field = 1
        in_imports = 1
        print $0
        next
    }

    # Detect end of Imports (next field starts with capital letter)
    in_imports && /^[A-Z]/ {
        # Add comma to last import line if missing, then add new package
        if (!added && last_import_line != "") {
            # Check if last line already has comma
            if (last_import_line !~ /,$/) {
                last_import_line = last_import_line ","
            }
            print last_import_line
            last_import_line = ""
        }
        # Add new package
        if (!added) {
            print "    " pkg ","
            added = 1
        }
        in_imports = 0
        print $0
        next
    }

    # Inside Imports field - buffer lines to handle comma on last line
    in_imports {
        # If we have a buffered line, print it now
        if (last_import_line != "") {
            print last_import_line
        }
        # Buffer current line
        last_import_line = $0
        next
    }

    # All other lines
    { print $0 }

    END {
        # Case 1: Imports field exists and we are still in it at EOF
        if (in_imports && !added) {
            # Print buffered last import line with comma
            if (last_import_line != "") {
                if (last_import_line !~ /,$/) {
                    last_import_line = last_import_line ","
                }
                print last_import_line
            }
            # Add new package (last item, no trailing comma)
            print "    " pkg
            added = 1
        }

        # Case 2: No Imports field exists at all - create new one at EOF
        if (!found_imports_field && !added) {
            print "Imports:"
            print "    " pkg
            added = 1
        }
    }
    ' "$temp_desc" > "$desc_file"

    if [[ $? -eq 0 ]]; then
        rm "$temp_desc"
        log_success "✅ Added $pkg to DESCRIPTION Imports"
        return 0
    else
        mv "$temp_desc" "$desc_file"
        log_error "Failed to update DESCRIPTION"
        return 1
    fi
}

#-----------------------------------------------------------------------------
# FUNCTION: add_package_to_renv_lock
# PURPOSE:  Add package entry to renv.lock using pure shell tools
# ARGS:     $1 - Package name
# RETURNS:  0 on success, 1 on failure
# DESCRIPTION:
#   Queries CRAN for package metadata and adds entry to renv.lock
#   using jq. No R required! Pure shell implementation.
#-----------------------------------------------------------------------------
add_package_to_renv_lock() {
    local pkg="$1"
    local renv_lock="renv.lock"

    if [[ ! -f "$renv_lock" ]]; then
        log_error "❌ renv.lock not found in current directory"
        log_error ""
        log_error "renv.lock is the package lock file that ensures reproducibility."
        log_error "It records exact package versions so collaborators install the same packages."
        log_error ""
        log_error "Create renv.lock with:"
        log_error "  R -e \"renv::init()\"  # Initialize renv (runs once)"
        log_error "  # Then install packages, and renv.lock auto-updates on R exit"
        log_error ""
        log_error "Or snapshot current packages:"
        log_error "  R -e \"renv::snapshot()\"  # Snapshot current packages to renv.lock"
        log_error ""
        log_error "See: docs/COLLABORATIVE_REPRODUCIBILITY.md for reproducibility details"
        return 1
    fi

    log_debug "Fetching metadata for $pkg from CRAN..."
    local pkg_info
    pkg_info=$(fetch_cran_package_info "$pkg")

    if [[ $? -ne 0 ]] || [[ -z "$pkg_info" ]]; then
        log_error "❌ Failed to fetch metadata for '$pkg' from CRAN"
        log_error ""
        log_error "Could not query package information from CRAN."
        log_error "Possible causes:"
        log_error "  - Package '$pkg' does not exist on CRAN"
        log_error "  - Network connection problem"
        log_error "  - CRAN API temporarily unavailable"
        log_error ""
        log_error "Recovery steps:"
        log_error "  1. Verify package exists on CRAN: https://cran.r-project.org/package=$pkg"
        log_error "  2. Check your internet connection: curl -I https://cran.r-project.org"
        log_error "  3. Try again: install.packages(\"$pkg\") in R session"
        log_error ""
        log_error "If package is not on CRAN, install from GitHub or local source"
        return 1
    fi

    # Extract version from CRAN response
    local version
    version=$(echo "$pkg_info" | jq -r '.Version // empty' 2>/dev/null)

    if [[ -z "$version" ]]; then
        log_error "❌ Could not determine version for '$pkg' from CRAN metadata"
        log_error ""
        log_error "The CRAN response did not contain version information."
        log_error "This may indicate:"
        log_error "  - Malformed response from CRAN API"
        log_error "  - Package metadata corruption"
        log_error "  - CRAN API changed format (needs update)"
        log_error ""
        log_error "Recovery steps:"
        log_error "  1. Check CRAN API manually: curl -s https://crandb.r-pkg.org/\"$pkg\""
        log_error "  2. Report to zzcollab: https://github.com/yourname/zzcollab/issues"
        return 1
    fi

    log_debug "Adding $pkg version $version to renv.lock..."

    # Create package entry JSON
    local package_entry
    package_entry=$(jq -n \
        --arg pkg "$pkg" \
        --arg ver "$version" \
        '{
            Package: $pkg,
            Version: $ver,
            Source: "Repository",
            Repository: "CRAN"
        }')

    # Add to renv.lock using jq
    local temp_lock
    temp_lock=$(mktemp)

    jq --argjson entry "$package_entry" \
       --arg pkg "$pkg" \
       '.Packages[$pkg] = $entry' \
       "$renv_lock" > "$temp_lock"

    if [[ $? -eq 0 ]]; then
        mv "$temp_lock" "$renv_lock"
        log_success "✅ Added $pkg ($version) to renv.lock"
        return 0
    else
        rm -f "$temp_lock"
        log_error "Failed to update renv.lock"
        return 1
    fi
}

#-----------------------------------------------------------------------------
# FUNCTION: update_renv_version_from_docker
# PURPOSE:  Update renv.lock to use r2u renv version from Docker base image
# DESCRIPTION:
#   Queries the Docker base image for its r2u renv version and updates
#   the local renv.lock file to match. This prevents renv from compiling
#   from source during Docker builds and runtime bootstrapping.
# ARGS:
#   $1 - Docker base image (e.g., "rocker/r-ver:4.4.2")
# RETURNS:
#   0 - renv version updated successfully
#   1 - Error occurred
# OUTPUTS:
#   Success/error messages to stderr
# NOTES:
#   - Requires Docker to be available
#   - Requires jq for JSON manipulation
#   - Performance: 60x speedup (binary vs source compile)
#-----------------------------------------------------------------------------
update_renv_version_from_docker() {
    local base_image="$1"
    local renv_lock="renv.lock"

    if [[ -z "$base_image" ]]; then
        log_error "Docker base image not specified"
        return 1
    fi

    if [[ ! -f "$renv_lock" ]]; then
        log_debug "renv.lock not found, skipping renv version update"
        return 0
    fi

    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        log_warn "jq not found, skipping renv version update"
        return 0
    fi

    log_info "Querying r2u renv version from $base_image..."

    # Query renv version from Docker image
    local renv_version
    renv_version=$(docker run --rm "$base_image" R --slave -e "cat(as.character(packageVersion('renv')))" 2>/dev/null)

    if [[ $? -ne 0 ]] || [[ -z "$renv_version" ]]; then
        log_warn "Could not detect renv version from Docker image, skipping update"
        return 0
    fi

    log_info "Detected r2u renv version: $renv_version"

    # Update renv.lock using jq
    local temp_lock
    temp_lock=$(mktemp)

    jq --arg ver "$renv_version" \
       '.Packages.renv.Version = $ver | .Packages.renv.Source = "Repository" | .Packages.renv.Repository = "CRAN"' \
       "$renv_lock" > "$temp_lock"

    if [[ $? -eq 0 ]]; then
        mv "$temp_lock" "$renv_lock"
        log_success "✅ Updated renv.lock to use r2u version $renv_version"
        log_info "   Performance: ~60x faster (binary install vs source compile)"
        return 0
    else
        rm -f "$temp_lock"
        log_error "Failed to update renv.lock"
        return 1
    fi
}

#==============================================================================
# PACKAGE EXTRACTION (PURE SHELL)
#==============================================================================

#-----------------------------------------------------------------------------
# FUNCTION: extract_code_packages
# PURPOSE:  Extract R package names from source code using pure shell tools
# DESCRIPTION:
#   Scans R source files for package references and extracts package names
#   using grep/sed. Handles library(), require(), namespace calls (pkg::fn),
#   and roxygen2 imports (@import, @importFrom).
# ARGS:
#   $@ - Directory paths to scan for R files
# RETURNS:
#   0 - Always succeeds
# OUTPUTS:
#   Package names to stdout, one per line (may contain duplicates)
# GLOBALS READ:
#   FILE_EXTENSIONS - Array of file extensions to search (.R, .Rmd, etc.)
# NOTES:
#   - Pure shell implementation (no R required on host)
#   - Extracts from: library(), require(), pkg::fn, @importFrom, @import
#   - Returns raw list with possible duplicates (use clean_packages() after)
#   - Requires closing parenthesis to avoid incomplete calls
#-----------------------------------------------------------------------------
extract_code_packages() {
    local dirs=("$@")
    local packages=()

    # Build find command for file extensions
    local find_pattern=""
    for ext in "${FILE_EXTENSIONS[@]}"; do
        if [[ -n "$find_pattern" ]]; then
            find_pattern="$find_pattern -o"
        fi
        find_pattern="$find_pattern -name \"*.$ext\""
    done

    # Build exclude pattern for files to skip
    local exclude_pattern=""
    for skip_file in "${SKIP_FILES[@]}"; do
        exclude_pattern="$exclude_pattern ! -path '$skip_file'"
    done

    # Find all R files and extract package references
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            # Extract library() and require() calls (skip commented lines)
            # BSD grep compatible: use -E for extended regex
            grep -v '^[[:space:]]*#' "$file" 2>/dev/null | \
                grep -E '(library|require)[[:space:]]*\(' 2>/dev/null | \
                sed -E 's/.*(library|require)[[:space:]]*\([[:space:]]*["\047]?([a-zA-Z][a-zA-Z0-9.]*)["\047]?[[:space:]]*\).*/\2/' || true

            # Extract namespace calls (package::function) - skip commented lines
            # BSD grep compatible: match pkg:: then remove ::
            grep -v '^[[:space:]]*#' "$file" 2>/dev/null | \
                grep -E '[a-zA-Z][a-zA-Z0-9.]*::' 2>/dev/null | \
                grep -oE '[a-zA-Z][a-zA-Z0-9.]*::' | \
                sed 's/:://' || true

            # Extract roxygen imports (these are comments but intentional)
            # BSD grep compatible
            grep -E '#'\''[[:space:]]*@importFrom[[:space:]]+[a-zA-Z]' "$file" 2>/dev/null | \
                sed -E 's/.*@importFrom[[:space:]]+([a-zA-Z0-9.]+).*/\1/' || true

            grep -E '#'\''[[:space:]]*@import[[:space:]]+[a-zA-Z]' "$file" 2>/dev/null | \
                sed -E 's/.*@import[[:space:]]+([a-zA-Z0-9.]+).*/\1/' || true
        fi
    done < <(eval "find ${dirs[*]} -type f \( $find_pattern \) $exclude_pattern 2>/dev/null")
}

#-----------------------------------------------------------------------------
# FUNCTION: clean_packages
# PURPOSE:  Clean, validate, and deduplicate extracted package names
# DESCRIPTION:
#   Takes a raw list of package names (possibly with duplicates, invalid names)
#   and returns a cleaned, deduplicated, sorted list of valid R package names.
#   Filters out base R packages that don't need declaration, validates package
#   name format according to R package naming rules, and removes duplicates.
# ARGS:
#   $@ - Raw package names (one per argument, may include duplicates/invalid)
# RETURNS:
#   0 - Always succeeds
# OUTPUTS:
#   Cleaned package names to stdout, one per line, sorted alphabetically
# GLOBALS READ:
#   BASE_PACKAGES - Array of base R packages to exclude
#   PLACEHOLDER_PACKAGES - Array of placeholder names to exclude
# VALIDATION RULES:
#   - Minimum 3 characters (R package requirement, avoid "my", "an", etc.)
#   - Must start with a letter (a-zA-Z)
#   - Can contain letters, numbers, and dots only
#   - Cannot start or end with a dot
#   - CRAN doesn't allow underscores, but BioConductor does (we allow them)
# FILTERS APPLIED:
#   1. Remove empty strings and names < 3 characters
#   2. Remove base R packages (base, utils, stats, etc.)
#   3. Remove placeholder packages (myproject, package, etc.)
#   4. Pattern-based filtering (very generic words)
#   5. Validate format: ^[a-zA-Z][a-zA-Z0-9.]*$
#   6. Remove names starting or ending with dots
#   7. Sort and deduplicate
# EXAMPLE:
#   packages=(dplyr ggplot2 dplyr base "" "a" ".invalid" "valid.pkg")
#   clean_packages "${packages[@]}"
#   # Output: ggplot2, valid.pkg, dplyr (sorted, base and invalid removed)
#-----------------------------------------------------------------------------
clean_packages() {
    local packages=("$@")
    local cleaned=()

    # Sort, deduplicate, filter base packages and placeholders
    for pkg in "${packages[@]}"; do
        # Skip if empty or too short (R packages must be at least 3 chars)
        # This filters out "my", "an", "is", "or", etc.
        if [[ -z "$pkg" ]] || [[ ${#pkg} -lt 3 ]]; then
            continue
        fi

        # Skip if base package
        local base_packages_str=" ${BASE_PACKAGES[*]} "
        if [[ "$base_packages_str" == *" ${pkg} "* ]]; then
            continue
        fi

        # Skip if placeholder package
        local placeholder_packages_str=" ${PLACEHOLDER_PACKAGES[*]} "
        if [[ "$placeholder_packages_str" == *" ${pkg} "* ]]; then
            log_debug "Filtering placeholder package: $pkg"
            continue
        fi

        # Pattern-based filtering: exclude overly generic single words
        # Common English words that appear in documentation examples
        case "$pkg" in
            # Pronouns and articles
            my|your|his|her|our|their|the|this|that)
                log_debug "Filtering generic word: $pkg"
                continue
                ;;
            # Generic nouns commonly used in examples
            file|dir|path|name|value|object|function|method|class)
                log_debug "Filtering generic word: $pkg"
                continue
                ;;
            # Words ending in "analysis" or "project" (usually examples)
            *analysis|*project|*study|*trial)
                # Only filter if lowercase (real packages often use CamelCase)
                if [[ "$pkg" =~ ^[a-z]+$ ]]; then
                    log_debug "Filtering example name: $pkg"
                    continue
                fi
                ;;
        esac

        # Validate package name format
        # R package rules: start with letter, contain letters/numbers/dots only
        if [[ "$pkg" =~ ^[a-zA-Z][a-zA-Z0-9.]*$ ]]; then
            # Additional validation: cannot start or end with dot
            if [[ ! "$pkg" =~ ^\. ]] && [[ ! "$pkg" =~ \.$ ]]; then
                cleaned+=("$pkg")
            fi
        fi
    done

    # Sort and deduplicate
    printf '%s\n' "${cleaned[@]}" | sort -u
}

#==============================================================================
# DESCRIPTION FILE PARSING (PURE SHELL)
#==============================================================================

#-----------------------------------------------------------------------------
# FUNCTION: parse_description_imports
# PURPOSE:  Extract package names from DESCRIPTION Imports field
# DESCRIPTION:
#   Parses the Imports field from an R package DESCRIPTION file using pure
#   awk, extracting package names while removing version constraints and
#   handling multi-line continuation. Returns clean package names suitable
#   for validation against code usage.
# ARGS:
#   None (operates on ./DESCRIPTION in current directory)
# RETURNS:
#   0 - Success (even if DESCRIPTION doesn't exist or has no Imports)
# OUTPUTS:
#   Package names to stdout, one per line, sorted and deduplicated
# FILES READ:
#   ./DESCRIPTION - R package metadata file
# AWK PROCESSING:
#   1. Identifies "Imports:" field start
#   2. Collects continuation lines (start with whitespace)
#   3. Stops at next field (line starting with capital letter)
#   4. Removes "Imports:" prefix
#   5. Removes version constraints: (>= x.y.z) or any (...)
#   6. Normalizes whitespace
#   7. Splits on commas
# VERSION CONSTRAINT HANDLING:
#   Removes all parenthetical expressions:
#   - "pkg (>= 1.0.0)" → "pkg"
#   - "pkg (>= 1.0.0),\n    pkg2 (< 2.0)" → "pkg", "pkg2"
# MULTI-LINE HANDLING:
#   DCF (Debian Control File) format allows continuation:
#   Imports: pkg1,
#       pkg2,
#       pkg3
#   All collected and processed together.
# EXAMPLE:
#   DESCRIPTION contains:
#     Imports:
#         dplyr (>= 1.0.0),
#         ggplot2
#   Output:
#     dplyr
#     ggplot2
#-----------------------------------------------------------------------------
parse_description_imports() {
    if [[ ! -f "DESCRIPTION" ]]; then
        return 0
    fi

    awk '
        BEGIN { in_imports = 0; imports = "" }

        # Start of Imports field
        /^Imports:/ {
            in_imports = 1
            imports = $0
            next
        }

        # Continuation lines (start with whitespace) while in Imports field
        in_imports && /^[[:space:]]/ {
            # Add space before appending to avoid concatenation issues
            imports = imports " " $0
            next
        }

        # Stop when we hit a new field (line that does not start with whitespace)
        in_imports && /^[A-Z]/ {
            in_imports = 0
        }

        # Process and output when done
        END {
            if (imports) {
                # Remove "Imports:" prefix
                gsub(/^Imports:[[:space:]]*/, "", imports)
                # Remove version constraints (handles multi-line constraints)
                gsub(/\([^)]*\)/, "", imports)
                # Normalize whitespace
                gsub(/[[:space:]]+/, " ", imports)
                # Split on commas
                gsub(/,/, "\n", imports)
                print imports
            }
        }
    ' DESCRIPTION | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort -u
}

#-----------------------------------------------------------------------------
# FUNCTION: parse_description_suggests
# PURPOSE:  Extract package names from DESCRIPTION Suggests field
# DESCRIPTION:
#   Parses the Suggests field from an R package DESCRIPTION file using pure
#   awk. Similar to parse_description_imports() but targets Suggests field.
#   Suggests packages are optional dependencies (testing, vignettes, examples).
# ARGS:
#   None (operates on ./DESCRIPTION in current directory)
# RETURNS:
#   0 - Success (even if DESCRIPTION doesn't exist or has no Suggests)
# OUTPUTS:
#   Package names to stdout, one per line, sorted and deduplicated
# FILES READ:
#   ./DESCRIPTION - R package metadata file
# SUGGESTS VS IMPORTS:
#   - Imports: Required dependencies, always installed
#   - Suggests: Optional dependencies, used for testing/vignettes/examples
#   - This function extracts Suggests to allow optional validation
# AWK PROCESSING:
#   Same as parse_description_imports() but for "Suggests:" field
# EXAMPLE:
#   DESCRIPTION contains:
#     Suggests:
#         testthat (>= 3.0.0),
#         knitr,
#         rmarkdown
#   Output:
#     knitr
#     rmarkdown
#     testthat
#-----------------------------------------------------------------------------
parse_description_suggests() {
    if [[ ! -f "DESCRIPTION" ]]; then
        return 0
    fi

    awk '
        BEGIN { in_suggests = 0; suggests = "" }

        # Start of Suggests field
        /^Suggests:/ {
            in_suggests = 1
            suggests = $0
            next
        }

        # Continuation lines (start with whitespace) while in Suggests field
        in_suggests && /^[[:space:]]/ {
            # Add space before appending to avoid concatenation issues
            suggests = suggests " " $0
            next
        }

        # Stop when we hit a new field
        in_suggests && /^[A-Z]/ {
            in_suggests = 0
        }

        # Process and output when done
        END {
            if (suggests) {
                gsub(/^Suggests:[[:space:]]*/, "", suggests)
                gsub(/\([^)]*\)/, "", suggests)
                gsub(/[[:space:]]+/, " ", suggests)
                gsub(/,/, "\n", suggests)
                print suggests
            }
        }
    ' DESCRIPTION | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort -u
}

#==============================================================================
# DESCRIPTION CLEANUP
#==============================================================================

#-----------------------------------------------------------------------------
# FUNCTION: remove_unused_packages_from_description
# PURPOSE:  Remove packages from DESCRIPTION that are not used in code
# DESCRIPTION:
#   Compares packages declared in DESCRIPTION Imports against packages
#   actually used in code. Removes unused packages from DESCRIPTION file
#   (except protected packages like renv). This helps keep DESCRIPTION
#   aligned with actual code dependencies.
# ARGS:
#   $1 - packages_in_code: Array of package names used in code
#   $2 - strict_mode: "true" or "false" for scanning scope
# RETURNS:
#   0 - Success (packages removed if any)
#   1 - Error (DESCRIPTION not found or not writable)
# OUTPUTS:
#   Informational messages about removed packages
# SIDE EFFECTS:
#   Modifies DESCRIPTION file in-place
# PROTECTED PACKAGES:
#   - renv: Always kept (infrastructure package)
# STRATEGY:
#   1. Parse current DESCRIPTION Imports
#   2. Find packages in DESCRIPTION but NOT in code
#   3. Remove unused packages (except protected ones)
#   4. Rewrite DESCRIPTION with awk
# EXAMPLE:
#   DESCRIPTION has: renv, dplyr, ggplot2
#   Code uses: dplyr
#   Result: Remove ggplot2, keep renv (protected) and dplyr (used)
#-----------------------------------------------------------------------------
remove_unused_packages_from_description() {
    local strict_mode="${1:-false}"

    # Verify file exists and is writable
    if ! verify_description_file "DESCRIPTION" true; then
        log_warn "Skipping package cleanup - DESCRIPTION file not available"
        return 1
    fi

    # Determine which directories to scan
    local dirs
    if [[ "$strict_mode" == "true" ]]; then
        dirs=("${STRICT_DIRS[@]}")
    else
        dirs=("${STANDARD_DIRS[@]}")
    fi

    # Get packages used in code
    local code_packages_raw
    mapfile -t code_packages_raw < <(extract_code_packages "${dirs[@]}")
    local code_packages
    mapfile -t code_packages < <(clean_packages "${code_packages_raw[@]}")

    # Get packages in DESCRIPTION
    local desc_packages=()
    while IFS= read -r pkg; do
        desc_packages+=("$pkg")
    done < <(parse_description_imports)

    # Find unused packages (in DESCRIPTION but NOT in code)
    local unused_packages=()
    for pkg in "${desc_packages[@]}"; do
        # Skip empty package names
        if [[ -z "$pkg" ]]; then
            continue
        fi

        # Protected package check
        if [[ "$pkg" == "renv" ]]; then
            continue
        fi

        # Check if package is used in code
        local found=false
        for code_pkg in "${code_packages[@]}"; do
            if [[ "$pkg" == "$code_pkg" ]]; then
                found=true
                break
            fi
        done

        if [[ "$found" == false ]]; then
            unused_packages+=("$pkg")
        fi
    done

    # No unused packages? Done
    if [[ ${#unused_packages[@]} -eq 0 ]]; then
        log_debug "No unused packages to remove from DESCRIPTION"
        return 0
    fi

    # Report what we're removing
    log_info "Removing ${#unused_packages[@]} unused package(s) from DESCRIPTION:"
    for pkg in "${unused_packages[@]}"; do
        log_info "  - $pkg"
    done

    # Create temporary file for new DESCRIPTION
    local tmp_desc=$(mktemp)

    # Build regex pattern for packages to remove
    local remove_pattern=""
    for pkg in "${unused_packages[@]}"; do
        if [[ -z "$remove_pattern" ]]; then
            remove_pattern="$pkg"
        else
            remove_pattern="$remove_pattern|$pkg"
        fi
    done

    # Remove unused packages from Imports section using awk
    awk -v pattern="^[[:space:]]*(${remove_pattern})[[:space:],]*\$" '
    /^Imports:/ { in_imports=1; print; next }
    in_imports {
        if (/^[A-Z]/) {
            # New section started, exit Imports
            in_imports=0
            print
            next
        }
        # Skip lines matching removal pattern
        if ($0 ~ pattern) {
            next
        }
        # Keep other lines
        print
    }
    !in_imports { print }
    ' DESCRIPTION > "$tmp_desc"

    # Replace DESCRIPTION with cleaned version
    mv "$tmp_desc" DESCRIPTION

    log_success "✅ Removed unused packages from DESCRIPTION"
    log_info "   Next renv::snapshot() will update renv.lock accordingly"
    return 0
}

#==============================================================================
# RENV.LOCK PARSING (USING JQ)
#==============================================================================

#-----------------------------------------------------------------------------
# FUNCTION: create_renv_lock
# PURPOSE:  Create a minimal renv.lock file for new projects
# DESCRIPTION:
#   Creates a minimal renv.lock JSON structure with R version and repository
#   configuration. This enables fully host-based project bootstrap without
#   requiring R to be installed. The Packages section starts empty and gets
#   populated by the auto-fix workflow.
# ARGS:
#   $1 - R version (optional, defaults to "4.5.1")
#   $2 - CRAN URL (optional, defaults to "https://cloud.r-project.org")
# RETURNS:
#   0 - Success (renv.lock created)
#   1 - Error (jq not available or write failed)
# OUTPUTS:
#   Creates ./renv.lock file in current directory
# DEPENDENCIES:
#   jq - Required for JSON generation
# EXAMPLE:
#   create_renv_lock "4.5.1" "https://cloud.r-project.org"
#-----------------------------------------------------------------------------
create_renv_lock() {
    local r_version="${1:-4.5.1}"
    local cran_url="${2:-https://cloud.r-project.org}"
    local renv_lock="renv.lock"

    # Check if jq is available
    if ! command -v jq &>/dev/null; then
        log_error "jq is required to create renv.lock"
        log_error "Install jq: brew install jq (macOS) or apt-get install jq (Linux)"
        return 1
    fi

    log_info "Creating minimal renv.lock for new project..."

    # Create minimal renv.lock structure using jq
    jq -n \
        --arg r_ver "$r_version" \
        --arg cran "$cran_url" \
        '{
            R: {
                Version: $r_ver,
                Repositories: [
                    {
                        Name: "CRAN",
                        URL: $cran
                    }
                ]
            },
            Packages: {}
        }' > "$renv_lock"

    if [[ $? -eq 0 ]] && [[ -f "$renv_lock" ]]; then
        log_success "✅ Created renv.lock (R $r_version)"
        return 0
    else
        log_error "Failed to create renv.lock"
        return 1
    fi
}

#-----------------------------------------------------------------------------
# FUNCTION: parse_renv_lock
# PURPOSE:  Extract package names from renv.lock file using jq
# DESCRIPTION:
#   Parses the renv.lock JSON file to extract all installed package names.
#   This provides the source of truth for what packages are actually locked
#   in the reproducible environment. Requires jq for JSON parsing.
# ARGS:
#   None (operates on ./renv.lock in current directory)
# RETURNS:
#   0 - Success (even if renv.lock doesn't exist or jq not available)
# OUTPUTS:
#   Package names to stdout, one per line, sorted and deduplicated
# FILES READ:
#   ./renv.lock - renv package lockfile (JSON format)
# DEPENDENCIES:
#   jq - Command-line JSON processor
#   - macOS: brew install jq
#   - Linux: apt-get install jq
#   - If jq not found, logs warning and returns gracefully
# RENV.LOCK STRUCTURE:
#   {
#     "R": {...},
#     "Packages": {
#       "packageA": {...},
#       "packageB": {...}
#     }
#   }
#   This function extracts keys from the "Packages" object.
# ERROR HANDLING:
#   - Missing renv.lock: Creates minimal renv.lock via create_renv_lock()
#   - Missing jq: Logs warning with installation instructions, returns success
#   - Invalid JSON: jq error silently caught (returns empty)
# WHY JQ INSTEAD OF SHELL:
#   - renv.lock is complex nested JSON
#   - Shell JSON parsing is fragile and error-prone
#   - jq is standard tool (available on all major platforms)
# EXAMPLE:
#   renv.lock contains:
#     {"Packages": {"dplyr": {...}, "ggplot2": {...}}}
#   Output:
#     dplyr
#     ggplot2
#-----------------------------------------------------------------------------
parse_renv_lock() {
    # Check if jq is available first (needed for both create and parse)
    if ! command -v jq &>/dev/null; then
        log_warn "jq not found, skipping renv.lock parsing"
        log_warn "Install jq: brew install jq (macOS) or apt-get install jq (Linux)"
        return 0
    fi

    # Create renv.lock if it doesn't exist
    if [[ ! -f "renv.lock" ]]; then
        log_info "No renv.lock found - creating one for new project"
        if ! create_renv_lock; then
            log_error "Failed to create renv.lock"
            return 1
        fi
    fi

    # Extract package names from Packages section
    jq -r '.Packages | keys[]' renv.lock 2>/dev/null | \
        grep -v '^$' | \
        sort -u || true
}

#==============================================================================
# VALIDATION LOGIC
#==============================================================================

#-----------------------------------------------------------------------------
# FUNCTION: compute_union_packages
# PURPOSE:  Compute union of packages from code, DESCRIPTION, and renv.lock
# DESCRIPTION:
#   Combines package lists from three sources into a single deduplicated set.
#   This union represents all packages that should be present in the environment.
#   Handles empty arrays gracefully and skips empty package names.
# ARGS:
#   $1 - code_packages: Space-separated or array-style package list from code
#   $2 - desc_imports: Packages declared in DESCRIPTION Imports
#   $3 - renv_packages: Packages in renv.lock
# RETURNS:
#   0 - Always succeeds
# OUTPUTS:
#   Union of all packages to stdout, one per line, deduplicated
# GLOBALS READ:
#   BASE_PACKAGES - Array of base R packages to exclude
# PROCESSING:
#   1. Adds all code packages
#   2. Adds DESCRIPTION packages not already in union
#   3. Adds renv.lock packages (excluding base) not already in union
#   4. Deduplicates by checking membership before adding
# SIDE EFFECTS:
#   None (pure function)
#-----------------------------------------------------------------------------
compute_union_packages() {
    local -n code_pkgs_ref="code_packages"
    local -n desc_pkgs_ref="desc_imports"
    local -n renv_pkgs_ref="renv_packages"

    local all_packages=()

    # Add packages from code
    for pkg in "${code_pkgs_ref[@]}"; do
        if [[ -n "$pkg" ]]; then
            all_packages+=("$pkg")
        fi
    done

    # Add packages from DESCRIPTION (dedup)
    for pkg in "${desc_pkgs_ref[@]}"; do
        if [[ -n "$pkg" ]]; then
            local found=false
            for existing in "${all_packages[@]}"; do
                if [[ "$pkg" == "$existing" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == false ]]; then
                all_packages+=("$pkg")
            fi
        fi
    done

    # Add packages from renv.lock (excluding base packages, dedup)
    for pkg in "${renv_pkgs_ref[@]}"; do
        if [[ -n "$pkg" ]]; then
            # Skip base R packages
            local base_pkgs_str=" ${BASE_PACKAGES[*]} "
            if [[ "$base_pkgs_str" == *" ${pkg} "* ]]; then
                continue
            fi

            # Check if not already in all_packages
            local found=false
            for existing in "${all_packages[@]}"; do
                if [[ "$pkg" == "$existing" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == false ]]; then
                all_packages+=("$pkg")
            fi
        fi
    done

    # Output union
    printf '%s\n' "${all_packages[@]}"
}

#-----------------------------------------------------------------------------
# FUNCTION: find_missing_from_description
# PURPOSE:  Find packages in union that are missing from DESCRIPTION
# DESCRIPTION:
#   Compares the union of all packages against DESCRIPTION Imports field
#   and returns packages that should be declared but aren't.
# ARGS:
#   $1 - all_packages: Array name of union packages
#   $2 - desc_imports: Array name of DESCRIPTION imports
# RETURNS:
#   0 - Always succeeds
# OUTPUTS:
#   Package names missing from DESCRIPTION to stdout, one per line
# SIDE EFFECTS:
#   None (pure function)
#-----------------------------------------------------------------------------
find_missing_from_description() {
    local -n all_pkgs_ref="$1"
    local -n desc_pkgs_ref="$2"

    local missing=()

    for pkg in "${all_pkgs_ref[@]}"; do
        # Skip empty package names
        if [[ -z "$pkg" ]]; then
            continue
        fi

        # Use literal string matching
        local desc_imports_str=" ${desc_pkgs_ref[*]} "
        if [[ "$desc_imports_str" != *" ${pkg} "* ]]; then
            missing+=("$pkg")
        fi
    done

    printf '%s\n' "${missing[@]}"
}

#-----------------------------------------------------------------------------
# FUNCTION: find_missing_from_lock
# PURPOSE:  Find packages in union that are missing from renv.lock
# DESCRIPTION:
#   Compares the union of all packages against renv.lock and returns
#   packages that should be locked but aren't. Excludes base R packages.
# ARGS:
#   $1 - all_packages: Array name of union packages
#   $2 - renv_packages: Array name of renv.lock packages
# RETURNS:
#   0 - Always succeeds
# OUTPUTS:
#   Package names missing from renv.lock to stdout, one per line
# SIDE EFFECTS:
#   None (pure function)
#-----------------------------------------------------------------------------
find_missing_from_lock() {
    local -n all_pkgs_ref="$1"
    local -n renv_pkgs_ref="$2"

    local missing=()

    for pkg in "${all_pkgs_ref[@]}"; do
        # Skip empty package names
        if [[ -z "$pkg" ]]; then
            continue
        fi

        # Skip base R packages (they don't need to be in renv.lock)
        local base_pkgs_str=" ${BASE_PACKAGES[*]} "
        if [[ "$base_pkgs_str" == *" ${pkg} "* ]]; then
            log_debug "Skipping base package: $pkg"
            continue
        fi

        # Check if package exists in renv.lock
        local renv_pkgs_str=" ${renv_pkgs_ref[*]} "
        if [[ "$renv_pkgs_str" != *" ${pkg} "* ]]; then
            missing+=("$pkg")
        fi
    done

    printf '%s\n' "${missing[@]}"
}

#-----------------------------------------------------------------------------
# FUNCTION: report_and_fix_missing_description
# PURPOSE:  Report and optionally fix packages missing from DESCRIPTION
# DESCRIPTION:
#   Handles the case where packages are used in code but not declared
#   in DESCRIPTION. Can report the issue or auto-fix by adding to DESCRIPTION.
# ARGS:
#   $1 - missing_from_desc: Array name of missing packages
#   $2 - verbose: "true" to list packages, "false" to show only count
#   $3 - auto_fix: "true" to attempt auto-fix, "false" to report only
# RETURNS:
#   0 - No missing packages or successfully fixed
#   1 - Missing packages found and auto-fix disabled
# OUTPUTS:
#   Error message and package list (if verbose) to stdout
#   Success/failure message if auto-fixing
# SIDE EFFECTS:
#   Modifies DESCRIPTION file if auto_fix=true
#-----------------------------------------------------------------------------
report_and_fix_missing_description() {
    local -n missing_ref="$1"
    local verbose="${2:-false}"
    local auto_fix="${3:-false}"

    if [[ ${#missing_ref[@]} -eq 0 ]]; then
        return 0
    fi

    log_error "Found ${#missing_ref[@]} packages missing from DESCRIPTION Imports"

    # List packages if verbose mode or auto-fix mode
    if [[ "$verbose" == "true" ]] || [[ "$auto_fix" == "true" ]]; then
        echo ""
        for pkg in "${missing_ref[@]}"; do
            echo "  - $pkg"
        done
        echo ""
    else
        echo ""
        log_info "Run with --verbose to see the list of missing packages"
        echo ""
    fi

    if [[ "$auto_fix" == "true" ]]; then
        log_info "Auto-fixing: Adding missing packages to DESCRIPTION..."
        local failed_packages=()

        for pkg in "${missing_ref[@]}"; do
            # Add to DESCRIPTION
            if ! add_package_to_description "$pkg"; then
                failed_packages+=("$pkg")
            fi
        done

        if [[ ${#failed_packages[@]} -eq 0 ]]; then
            log_success "✅ All missing packages added to DESCRIPTION"
            return 0
        else
            log_error "Failed to add packages to DESCRIPTION: ${failed_packages[*]}"
            return 1
        fi
    else
        local pkg_vector=$(format_r_package_vector "${missing_ref[@]}")
        echo "Fix with auto-fix flag:"
        echo "  bash modules/validation.sh --fix"
        echo ""
        echo "Or manually add to DESCRIPTION Imports field"
        return 1
    fi
}

#-----------------------------------------------------------------------------
# FUNCTION: report_and_fix_missing_lock
# PURPOSE:  Report and optionally fix packages missing from renv.lock
# DESCRIPTION:
#   Handles the case where packages are declared but not locked in renv.lock.
#   This breaks reproducibility. Can report the issue or auto-fix by querying CRAN.
#
#   WITH UPFRONT CRAN VALIDATION:
#   - Filters packages through CRAN validation BEFORE attempting to add
#   - CRAN packages: auto-add to renv.lock
#   - Non-CRAN packages (local, GitHub, BioConductor): skip gracefully with guidance
#   - Prevents false positives and confusing error messages
# ARGS:
#   $1 - missing_from_lock: Array name of missing packages
#   $2 - verbose: "true" to list packages, "false" to show only count
#   $3 - auto_fix: "true" to attempt auto-fix, "false" to report only
# RETURNS:
#   0 - No missing packages or successfully fixed (including non-CRAN packages skipped)
#   1 - CRAN packages failed to add or auto-fix disabled with CRAN packages pending
# OUTPUTS:
#   Error message and package list (if verbose) to stdout
#   Success/failure message if auto-fixing
#   Guidance for non-CRAN packages found
# SIDE EFFECTS:
#   Modifies renv.lock file if auto_fix=true (queries CRAN API for CRAN packages only)
#-----------------------------------------------------------------------------
report_and_fix_missing_lock() {
    local -n missing_ref="$1"
    local verbose="${2:-false}"
    local auto_fix="${3:-false}"

    if [[ ${#missing_ref[@]} -eq 0 ]]; then
        return 0
    fi

    # UPFRONT INSTALLABLE PACKAGE VALIDATION: Check CRAN, Bioconductor, GitHub
    local installable_packages=()
    local non_installable_packages=()

    log_info "Validating ${#missing_ref[@]} packages against CRAN/Bioconductor/GitHub..."
    for pkg in "${missing_ref[@]}"; do
        if is_installable_package "$pkg"; then
            installable_packages+=("$pkg")
        else
            non_installable_packages+=("$pkg")
            log_debug "  ⚠️  $pkg (not found in any standard repository)"
        fi
    done

    # If no packages found in any category, we're done
    if [[ ${#installable_packages[@]} -eq 0 ]] && [[ ${#non_installable_packages[@]} -eq 0 ]]; then
        return 0
    fi

    # Report findings
    if [[ ${#installable_packages[@]} -gt 0 ]]; then
        log_error "Found ${#installable_packages[@]} installable packages (CRAN/Bioconductor/GitHub) missing from renv.lock"
    fi
    if [[ ${#non_installable_packages[@]} -gt 0 ]]; then
        log_warn "Found ${#non_installable_packages[@]} non-installable packages (skipping validation)"
    fi

    # List packages if verbose mode or auto-fix mode
    if [[ "${#installable_packages[@]}" -gt 0 ]] && ([[ "$verbose" == "true" ]] || [[ "$auto_fix" == "true" ]]); then
        echo ""
        echo "Installable packages to add:"
        for pkg in "${installable_packages[@]}"; do
            echo "  - $pkg"
        done
    fi
    if [[ "${#non_installable_packages[@]}" -gt 0 ]] && ([[ "$verbose" == "true" ]] || [[ "$auto_fix" == "true" ]]); then
        echo ""
        echo "Non-installable packages (will be skipped):"
        for pkg in "${non_installable_packages[@]}"; do
            echo "  - $pkg"
        done
    fi
    echo ""

    # Only report reproducibility issue if we have installable packages missing
    if [[ ${#installable_packages[@]} -gt 0 ]]; then
        echo "Missing installable packages break reproducibility! Collaborators cannot restore your environment."
        echo ""
    fi

    # Handle installable packages
    if [[ "$auto_fix" == "true" ]] && [[ ${#installable_packages[@]} -gt 0 ]]; then
        log_info "Auto-fixing: Adding ${#installable_packages[@]} installable packages to renv.lock..."
        local failed_packages=()

        for pkg in "${installable_packages[@]}"; do
            if ! add_package_to_renv_lock "$pkg"; then
                failed_packages+=("$pkg")
            fi
        done

        if [[ ${#failed_packages[@]} -eq 0 ]]; then
            log_success "✅ All installable packages added to renv.lock"
            echo ""
            echo "Next steps:"
            echo "  1. Start R to auto-install packages: make r"
            echo "     (Auto-restore will install all dependencies automatically)"
            echo "  2. Rebuild Docker image: make docker-build"
            echo "  3. Commit changes: git add DESCRIPTION renv.lock && git commit -m 'Add packages'"
        else
            log_error "Failed to add packages: ${failed_packages[*]}"
            echo ""
            echo "These packages may have network issues. Add them manually:"
            echo "  make docker-zsh"
            local pkg_vector=$(format_r_package_vector "${failed_packages[@]}")
            echo "  R> renv::install($pkg_vector)"
            echo "  R> quit()"
        fi
    elif [[ "$auto_fix" != "true" ]] && [[ ${#installable_packages[@]} -gt 0 ]]; then
        local pkg_vector=$(format_r_package_vector "${installable_packages[@]}")
        echo "Fix installable packages with auto-fix flag:"
        echo "  bash modules/validation.sh --fix"
        echo ""
        echo "Or manually in container:"
        echo "  make docker-zsh"
        echo "  R> renv::install($pkg_vector)"
        echo "  R> quit()"
    fi

    # Handle non-installable packages
    if [[ ${#non_installable_packages[@]} -gt 0 ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Non-installable packages detected (not in CRAN/Bioconductor/GitHub):"
        echo ""
        for pkg in "${non_installable_packages[@]}"; do
            echo "  • $pkg"
        done
        echo ""
        echo "These packages must be handled manually in your Docker container:"
        echo ""
        echo "  Option 1: Local package (development)"
        echo "    • Ensure it's available locally: /path/to/$pkg"
        echo "    • Install in R: remotes::install_local('/path/to/$pkg')"
        echo ""
        echo "  Option 2: GitHub package"
        echo "    • Use format 'owner/repo' in DESCRIPTION or:"
        echo "    • Install in R: remotes::install_github('owner/repo')"
        echo ""
        echo "  Option 3: BioConductor package"
        echo "    • Install in R: BiocManager::install('pkgname')"
        echo ""
        echo "  Then snapshot to lock in renv.lock: renv::snapshot()"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
    fi

    # Determine return code:
    # 0 if: no installable packages left, OR all installable packages successfully fixed
    # 1 if: installable packages exist and auto-fix is disabled, OR some installable packages failed
    if [[ ${#installable_packages[@]} -eq 0 ]]; then
        # No installable packages (only non-installable, which are handled gracefully)
        return 0
    elif [[ "$auto_fix" != "true" ]]; then
        # Installable packages exist but auto-fix disabled
        return 1
    elif [[ ${#failed_packages[@]} -eq 0 ]]; then
        # Installable packages all successfully fixed
        return 0
    else
        # Some installable packages failed
        return 1
    fi
}

#-----------------------------------------------------------------------------
# FUNCTION: validate_package_environment
# PURPOSE:  Main validation logic for R package environment consistency
# DESCRIPTION:
#   Validates that all R packages used in source code are properly declared
#   in DESCRIPTION Imports field and locked in renv.lock for reproducibility.
#   This is the core validation function that orchestrates package extraction,
#   parsing, and comparison. Runs entirely on host without requiring R.
# ARGS:
#   $1 - strict_mode: "true" to scan all directories (tests/, vignettes/),
#                     "false" (default) to scan only standard dirs (R/, scripts/)
#   $2 - auto_fix: "true" to attempt automatic fixes (NOT YET IMPLEMENTED),
#                  "false" (default) to only report issues
#   $3 - verbose: "true" to list all missing packages,
#                 "false" (default) to show only count
# RETURNS:
#   0 - All packages properly declared (validation passed)
#   1 - Missing packages found (validation failed)
# OUTPUTS:
#   Progress messages and validation results to stdout
#   Error messages for missing packages
# GLOBALS READ:
#   STANDARD_DIRS - Array of standard directories to scan (R/, scripts/, analysis/)
#   STRICT_DIRS - Array of all directories in strict mode (adds tests/, vignettes/, inst/)
# VALIDATION WORKFLOW:
#   1. Extract packages from source code (library, require, ::, @import)
#   2. Clean and validate extracted package names
#   3. Parse DESCRIPTION Imports field
#   4. Parse renv.lock (optional, for informational purposes)
#   5. Compare code packages vs DESCRIPTION
#   6. Report any packages used in code but not declared in DESCRIPTION
# STRICT MODE:
#   Standard mode: Scans R/, scripts/, analysis/ only
#   Strict mode: Also scans tests/, vignettes/, inst/
#   Rationale: Tests and vignettes can use Suggests packages, which may not
#              be in Imports. Strict mode helps catch undeclared Suggests.
# AUTO-FIX (NOT YET IMPLEMENTED):
#   Would add missing packages to DESCRIPTION automatically
#   Currently logs message directing user to manual fix or R script
# REPRODUCIBILITY SIGNIFICANCE:
#   This validation ensures that anyone cloning the project can:
#   1. Install dependencies from DESCRIPTION
#   2. Restore exact versions from renv.lock
#   3. Run all code without "package not found" errors
# EXAMPLE USAGE:
#   validate_package_environment "false" "false"  # Standard validation
#   validate_package_environment "true" "false"   # Strict validation
#-----------------------------------------------------------------------------
validate_package_environment() {
    local strict_mode="${1:-false}"
    local auto_fix="${2:-false}"
    local verbose="${3:-false}"

    log_info "Validating package dependencies..."

    # Step 1: Extract packages from code
    local dirs=("${STANDARD_DIRS[@]}")
    if [[ "$strict_mode" == "true" ]]; then
        dirs=("${STRICT_DIRS[@]}")
        log_info "Running in strict mode (scanning all directories)"
    fi

    log_info "Scanning for R files in: ${dirs[*]}"
    local code_packages_raw
    mapfile -t code_packages_raw < <(extract_code_packages "${dirs[@]}")
    local code_packages
    mapfile -t code_packages < <(clean_packages "${code_packages_raw[@]}")

    # Step 2: Parse DESCRIPTION
    local desc_imports
    mapfile -t desc_imports < <(parse_description_imports)

    # Step 3: Parse renv.lock
    local renv_packages
    mapfile -t renv_packages < <(parse_renv_lock)

    # Step 4: Report findings
    log_info "Found ${#code_packages[@]} packages in code"
    log_info "Found ${#desc_imports[@]} packages in DESCRIPTION Imports"
    log_info "Found ${#renv_packages[@]} packages in renv.lock"

    # Step 5: Compute union of all packages from all three sources
    local all_packages=()
    mapfile -t all_packages < <(compute_union_packages)
    log_info "Union of all packages: ${#all_packages[@]} packages"

    # Step 6: Find packages missing from DESCRIPTION
    local missing_from_desc=()
    mapfile -t missing_from_desc < <(find_missing_from_description all_packages desc_imports)

    # Step 7: Check union → renv.lock consistency
    log_debug "Checking union → renv.lock consistency..."
    local missing_from_lock=()
    mapfile -t missing_from_lock < <(find_missing_from_lock all_packages renv_packages)

    # Step 8: Handle missing packages from DESCRIPTION
    if ! report_and_fix_missing_description missing_from_desc "$verbose" "$auto_fix"; then
        return 1
    fi

    # Step 9: Report union → renv.lock issues
    if ! report_and_fix_missing_lock missing_from_lock "$verbose" "$auto_fix"; then
        return 1
    fi

    log_success "✅ All packages properly declared in DESCRIPTION"
    log_success "✅ All DESCRIPTION imports are locked in renv.lock"
    return 0
}

#-----------------------------------------------------------------------------
# FUNCTION: validate_and_report
# PURPOSE:  User-friendly wrapper around validate_package_environment
# DESCRIPTION:
#   Convenience function that calls validate_package_environment() and
#   provides actionable feedback on how to fix issues. Formats output
#   for end-user consumption with clear success/failure messages and
#   instructions for resolving validation failures.
# ARGS:
#   $1 - strict_mode: "true" or "false" (default), passed to validation
# RETURNS:
#   0 - Validation passed
#   1 - Validation failed (packages missing from DESCRIPTION)
# OUTPUTS:
#   Success message if validation passes
#   Error message plus fix instructions if validation fails
# FIX INSTRUCTIONS PROVIDED:
#   1. Manual addition to DESCRIPTION Imports field
#   2. Run R validation script with --fix flag
#   3. Install packages inside container (auto-snapshot on exit)
# USER EXPERIENCE FOCUS:
#   This function prioritizes clear, actionable guidance over technical details
#   Goal: Make it easy for researchers to fix validation issues themselves
# EXAMPLE OUTPUT ON FAILURE:
#   Package environment validation failed
#
#   To fix missing packages, you can:
#     1. Add them manually to DESCRIPTION Imports field
#     2. Run: Rscript validate_package_environment.R --fix
#     3. Inside container: renv::install() then exit (auto-snapshot)
#-----------------------------------------------------------------------------
validate_and_report() {
    local strict_mode="${1:-true}"
    local auto_fix="${2:-true}"
    local verbose="${3:-false}"

    if validate_package_environment "$strict_mode" "$auto_fix" "$verbose"; then
        log_success "Package environment validation passed"

        # Clean up unused packages from DESCRIPTION
        # This runs after validation to ensure all used packages are declared
        log_debug "Checking for unused packages in DESCRIPTION..."
        remove_unused_packages_from_description "$strict_mode"

        return 0
    else
        log_error "Package environment validation failed"
        echo ""
        echo "To fix missing packages, you can:"
        echo "  1. Add them manually to DESCRIPTION Imports field"
        echo "  2. Run: Rscript validate_package_environment.R --fix"
        echo "  3. Inside container: renv::install() then exit (auto-snapshot)"
        echo ""
        return 1
    fi
}

#==============================================================================
# COMMAND LINE INTERFACE
#==============================================================================

#-----------------------------------------------------------------------------
# FUNCTION: main
# PURPOSE:  Command-line entry point for validation module
# DESCRIPTION:
#   Provides CLI interface to the validation system. Parses command-line
#   arguments, displays help, and invokes validate_and_report() with
#   appropriate settings. Only runs when module is executed directly
#   (not when sourced by other scripts).
# ARGS:
#   --strict : Enable strict mode (scan tests/, vignettes/, inst/)
#   --help|-h : Display usage information and exit
# RETURNS:
#   0 - Validation passed
#   1 - Validation failed or invalid arguments
#   (exits script, does not return to caller)
# USAGE:
#   ./modules/validation.sh              # Standard validation
#   ./modules/validation.sh --strict     # Strict validation
#   ./modules/validation.sh --help       # Show help
# EXECUTION GUARD:
#   Only runs if ${BASH_SOURCE[0]} == ${0}
#   This allows module to be:
#   - Executed directly: Runs main()
#   - Sourced by other scripts: Provides functions only
# CLI DESIGN:
#   - Simple, focused interface (validation-specific)
#   - Clear help text with examples
#   - Minimal dependencies (just bash, grep, sed, awk, jq)
# HOST REQUIREMENTS:
#   - Standard Unix tools: bash, grep, sed, awk, find
#   - jq: For renv.lock parsing (optional, warns if missing)
#   - No R installation required on host!
# INTEGRATION:
#   This script is called by:
#   - Makefile targets (make check-renv, make check-renv-strict)
#   - Docker exit hooks (auto-validation after container exit)
#   - Manual validation by developers
# WHY HOST-BASED VALIDATION:
#   Running on host (not in Docker) enables:
#   - Fast validation without container startup
#   - Pre-commit hooks and CI/CD integration
#   - Validation before Docker build (catch issues early)
#-----------------------------------------------------------------------------
main() {
    local strict_mode=true
    local auto_fix=true
    local verbose=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --strict)
                strict_mode=true
                shift
                ;;
            --no-strict)
                strict_mode=false
                shift
                ;;
            --fix)
                auto_fix=true
                shift
                ;;
            --no-fix)
                auto_fix=false
                shift
                ;;
            --verbose|-v)
                verbose=true
                shift
                ;;
            --system-deps)
                detect_missing_system_deps "${2:-.}/Dockerfile"
                shift 2
                ;;
            --help|-h)
                cat <<EOF
Usage: validation.sh [OPTIONS]

Validate R package dependencies without requiring R on host.

DEFAULTS:
    Strict mode and auto-fix are ENABLED by default for comprehensive validation.

OPTIONS:
    --strict           Enable strict mode (scan tests/, vignettes/, root) [DEFAULT]
    --no-strict        Disable strict mode (scan only R/, scripts/, analysis/, root)
    --fix              Auto-add missing packages to renv.lock via CRAN API [DEFAULT]
    --no-fix           Report issues without auto-fixing
    --system-deps      Check for missing system dependencies in Dockerfile
    --verbose, -v      List all missing packages (always enabled with --fix)
    --help, -h         Show this help message

EXAMPLES:
    validation.sh                        # Full validation with auto-fix (recommended)
    validation.sh --verbose              # Show list of missing packages
    validation.sh --no-fix               # Validation only, no auto-add
    validation.sh --no-strict            # Skip tests/ and vignettes/ directories
    validation.sh --system-deps          # Check for missing system dependencies
    validation.sh -v --no-fix            # Verbose validation without auto-fix

REQUIREMENTS:
    - jq (for renv.lock parsing and editing): brew install jq
    - curl (for CRAN API queries): pre-installed on macOS/Linux
    - Standard Unix tools: grep, sed, awk, find

AUTO-FIX IMPLEMENTATION:
    Pure shell implementation! No R required on host.
    - Queries CRAN API (crandb.r-pkg.org) for package metadata
    - Adds package entries to renv.lock using jq
    - Works anywhere: macOS, Linux, CI/CD, Docker host
    - Handles CRAN packages automatically
    - Non-CRAN packages (GitHub, Bioconductor) require manual installation

WORKFLOW:
    1. Run validation: bash modules/validation.sh
    2. Missing packages auto-added to renv.lock
    3. Rebuild Docker image: make docker-build
    4. Commit: git add renv.lock && git commit
EOF
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Run validation
    validate_and_report "$strict_mode" "$auto_fix" "$verbose"
}

##############################################################################
# SYSTEM DEPENDENCY VALIDATION
##############################################################################

##############################################################################
# FUNCTION: detect_missing_system_deps
# PURPOSE:  Detect R packages that need system dependencies not in Dockerfile
# USAGE:    detect_missing_system_deps "Dockerfile"
# ARGS:     $1 - Path to Dockerfile to scan (optional, defaults to "./Dockerfile")
# RETURNS:  0 if all deps found, 1 if missing deps detected
# DESCRIPTION:
#   Scans codebase for R packages, looks up system dependencies,
#   and checks if they are installed in the provided Dockerfile.
#   Reports missing dependencies with installation suggestions.
##############################################################################
detect_missing_system_deps() {
    local dockerfile="${1:-./Dockerfile}"

    # Check if system_deps_map module is available
    if ! source "${MODULES_DIR}/system_deps_map.sh" 2>/dev/null; then
        log_warn "system_deps_map.sh not available - skipping system dependency check"
        return 0
    fi

    log_info "Checking for missing system dependencies..."

    if [[ ! -f "$dockerfile" ]]; then
        log_warn "Dockerfile not found: $dockerfile"
        return 0
    fi

    # Extract all R packages from codebase
    local all_packages=$(extract_code_packages | sort -u)

    if [[ -z "$all_packages" ]]; then
        log_info "No R packages found in codebase"
        return 0
    fi

    local missing_build_deps=()
    local missing_runtime_deps=()
    local packages_with_missing_deps=()

    # Check each package for system dependencies
    while IFS= read -r package; do
        [[ -z "$package" ]] && continue

        # Get build and runtime deps for this package
        local build_deps=$(get_package_build_deps "$package")
        local runtime_deps=$(get_package_runtime_deps "$package")

        if [[ -z "$build_deps" ]]; then
            continue
        fi

        # Check if build deps are in Dockerfile
        local missing_build=()
        for dep in $build_deps; do
            if ! grep -q "$dep" "$dockerfile"; then
                missing_build+=("$dep")
            fi
        done

        # Check if runtime deps are in Dockerfile
        local missing_runtime=()
        for dep in $runtime_deps; do
            if ! grep -q "$dep" "$dockerfile"; then
                missing_runtime+=("$dep")
            fi
        done

        # Collect results
        if [[ ${#missing_build[@]} -gt 0 ]] || [[ ${#missing_runtime[@]} -gt 0 ]]; then
            packages_with_missing_deps+=("$package")
            missing_build_deps+=("${missing_build[@]}")
            missing_runtime_deps+=("${missing_runtime[@]}")
        fi
    done <<< "$all_packages"

    # Report findings
    if [[ ${#packages_with_missing_deps[@]} -eq 0 ]]; then
        log_success "✓ All R packages have required system dependencies"
        return 0
    fi

    # Format missing deps for display
    log_warn ""
    log_warn "⚠ Missing system dependencies detected!"
    log_warn ""

    for package in "${packages_with_missing_deps[@]}"; do
        local build=$(get_package_build_deps "$package")
        local runtime=$(get_package_runtime_deps "$package")

        echo ""
        log_warn "  Package: $package"

        if [[ -n "$build" ]]; then
            log_warn "    Build-time: $build"
        fi

        if [[ -n "$runtime" ]]; then
            log_warn "    Runtime:    $runtime"
        fi
    done

    # Provide instructions
    echo ""
    log_warn "═══════════════════════════════════════════════════════════════"
    log_warn "To fix missing system dependencies:"
    log_warn ""
    log_warn "1. Edit the Dockerfile"
    log_warn ""
    log_warn "2. Add to CUSTOM_SYSTEM_DEPS_BUILD_START section (builder stage):"
    log_warn ""
    log_warn "   RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \\"
    log_warn "       --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \\"
    log_warn "       set -ex && \\"
    log_warn "       apt-get update && \\"
    log_warn "       apt-get install -y --no-install-recommends \\"

    # Print unique missing build deps
    for dep in $(printf '%s\n' "${missing_build_deps[@]}" | sort -u); do
        log_warn "           $dep \\"
    done

    log_warn ""
    log_warn "3. Add to CUSTOM_SYSTEM_DEPS_RUNTIME_START section (runtime stage):"
    log_warn ""
    log_warn "   RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \\"
    log_warn "       --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \\"
    log_warn "       set -ex && \\"
    log_warn "       apt-get update && \\"
    log_warn "       apt-get install -y --no-install-recommends \\"

    # Print unique missing runtime deps
    for dep in $(printf '%s\n' "${missing_runtime_deps[@]}" | sort -u); do
        log_warn "           $dep \\"
    done

    log_warn ""
    log_warn "4. Rebuild Docker image:"
    log_warn "   make docker-build"
    log_warn "═══════════════════════════════════════════════════════════════"
    echo ""

    return 1
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
