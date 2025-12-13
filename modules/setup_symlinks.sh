#!/bin/bash
# Blog Post Symlink Setup
# Creates dual symlink structure for Quarto blog posts in ZZCOLLAB projects
#
# Usage: ./setup_symlinks.sh [--remove | --status | --help]
#   (no args)  : Create symlinks for blog post structure
#   --remove   : Remove blog post symlinks
#   --status   : Show current symlink status
#   --help     : Show this help message
#
# This script creates symlinks at two levels:
#   1. Post root: For Quarto to find index.qmd and for HTML to resolve paths
#   2. analysis/paper/: For intuitive editing (paths like figures/plot.png)
#
# After running, you can write paths in analysis/paper/index.qmd like:
#   ![Plot](figures/plot.png)
#   ![Hero](media/images/hero.jpg)
#
# And they will resolve correctly both when editing and in rendered HTML.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored output
info() { echo -e "${BLUE}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

# Check if we're in a ZZCOLLAB project root
check_project_root() {
    if [[ ! -f "DESCRIPTION" ]] && [[ ! -f ".zzcollab_project" ]]; then
        error "Not in a ZZCOLLAB project root (no DESCRIPTION or .zzcollab_project found)"
        echo "  Run this script from the post/project root directory."
        exit 1
    fi

    if [[ ! -d "analysis" ]]; then
        error "No analysis/ directory found"
        echo "  This doesn't appear to be a valid ZZCOLLAB project."
        exit 1
    fi
}

# Create a symlink safely
create_symlink() {
    local target="$1"
    local link_name="$2"
    local description="$3"

    if [[ -L "$link_name" ]]; then
        local current_target
        current_target=$(readlink "$link_name")
        if [[ "$current_target" == "$target" ]]; then
            info "$description: already exists (correct)"
            return 0
        else
            warn "$description: exists but points to '$current_target', updating..."
            rm "$link_name"
        fi
    elif [[ -e "$link_name" ]]; then
        error "$description: '$link_name' exists but is not a symlink"
        echo "  Remove it manually if you want to create the symlink."
        return 1
    fi

    ln -s "$target" "$link_name"
    success "$description: created ($link_name → $target)"
}

# Remove a symlink safely
remove_symlink() {
    local link_name="$1"
    local description="$2"

    if [[ -L "$link_name" ]]; then
        rm "$link_name"
        success "$description: removed"
    elif [[ -e "$link_name" ]]; then
        warn "$description: '$link_name' is not a symlink, skipping"
    else
        info "$description: doesn't exist"
    fi
}

# Find the zzcollab templates directory
find_templates_dir() {
    # Check common locations for zzcollab templates
    local locations=(
        "${ZZCOLLAB_HOME:-}/templates"
        "$HOME/.zzcollab/templates"
        "/usr/local/share/zzcollab/templates"
        "$(dirname "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")")"
    )

    for loc in "${locations[@]}"; do
        if [[ -f "$loc/index.qmd" ]]; then
            echo "$loc"
            return 0
        fi
    done

    return 1
}

# Update .Rbuildignore with blog-specific entries
update_rbuildignore() {
    local rbuildignore=".Rbuildignore"

    # Blog-specific entries to add
    local entries=(
        "^index\\.qmd$"
        "^index\\.html$"
        "^index_files$"
        "^figures$"
        "^media$"
        "^\\.zzcollab$"
    )

    if [[ ! -f "$rbuildignore" ]]; then
        # Create new .Rbuildignore with blog entries
        printf '%s\n' "${entries[@]}" > "$rbuildignore"
        success "Created .Rbuildignore with blog post entries"
        return 0
    fi

    # Ensure file ends with newline before appending
    if [[ -s "$rbuildignore" ]] && [[ "$(tail -c 1 "$rbuildignore" | wc -l)" -eq 0 ]]; then
        echo "" >> "$rbuildignore"
    fi

    # Add entries that don't already exist
    local added=0
    for entry in "${entries[@]}"; do
        if ! grep -qF "$entry" "$rbuildignore" 2>/dev/null; then
            echo "$entry" >> "$rbuildignore"
            ((added++))
        fi
    done

    if [[ $added -gt 0 ]]; then
        success "Added $added blog-specific entries to .Rbuildignore"
    else
        info ".Rbuildignore already has blog entries"
    fi
}

# Copy index.qmd template if it doesn't exist
copy_index_template() {
    local target="analysis/paper/index.qmd"

    if [[ -f "$target" ]]; then
        info "index.qmd already exists, skipping template copy"
        return 0
    fi

    local templates_dir
    if templates_dir=$(find_templates_dir); then
        local template="$templates_dir/index.qmd"
        if [[ -f "$template" ]]; then
            cp "$template" "$target"
            success "Copied index.qmd template to analysis/paper/"
            return 0
        fi
    fi

    # Fallback: create minimal template
    warn "Could not find index.qmd template, creating minimal version"
    cat > "$target" << 'TEMPLATE'
---
title: "Post Title"
subtitle: "Post subtitle"
author: "Your Name"
date: "2025-01-01"
categories: [Category1, Category2]
description: "Brief description of the post"
image: "media/images/hero.jpg"
draft: true
execute:
  echo: true
  warning: false
  message: false
format:
  html:
    code-fold: false
---

# Introduction

Your content here.

# Analysis

```{r}
#| label: setup
library(tidyverse)
```

# Reproducibility

```{r}
#| echo: false
sessionInfo()
```
TEMPLATE
    success "Created minimal index.qmd template"
}

# Create all blog post symlinks
create_symlinks() {
    info "Setting up blog post structure..."
    echo ""

    # Ensure required directories exist
    mkdir -p analysis/paper
    mkdir -p analysis/figures
    mkdir -p analysis/media/images
    mkdir -p analysis/media/audio
    mkdir -p analysis/media/video
    mkdir -p analysis/data/raw_data
    mkdir -p analysis/data/derived_data

    success "Created media directories"
    echo ""

    # Copy index.qmd template
    copy_index_template
    echo ""

    echo "Root-level symlinks (for Quarto/HTML):"

    # Root-level symlinks
    create_symlink "analysis/paper/index.qmd" "index.qmd" "  index.qmd"
    create_symlink "analysis/figures" "figures" "  figures/"
    create_symlink "analysis/media" "media" "  media/"
    create_symlink "analysis/data" "data" "  data/"

    echo ""
    echo "analysis/paper/ symlinks (for intuitive editing):"

    # analysis/paper/ symlinks
    cd analysis/paper
    create_symlink "../figures" "figures" "  figures/"
    create_symlink "../media" "media" "  media/"
    create_symlink "../data" "data" "  data/"
    cd ../..

    echo ""

    # Update .Rbuildignore for R CMD check compatibility
    update_rbuildignore

    echo ""
    success "Symlink structure created!"
    echo ""
    echo "Next steps:"
    echo "  1. Create your blog post: analysis/paper/index.qmd"
    echo "  2. Add images to: analysis/media/images/"
    echo "  3. Add analysis scripts to: analysis/scripts/"
    echo "  4. Generated figures go to: analysis/figures/"
    echo ""
    echo "In your index.qmd, use simple paths:"
    echo '  ![Plot](figures/plot.png)'
    echo '  ![Hero](media/images/hero.jpg)'
}

# Remove all blog post symlinks
remove_symlinks() {
    info "Removing blog post symlinks..."
    echo ""

    echo "Removing root-level symlinks:"
    remove_symlink "index.qmd" "  index.qmd"
    remove_symlink "figures" "  figures/"
    remove_symlink "media" "  media/"
    remove_symlink "data" "  data/"

    echo ""
    echo "Removing analysis/paper/ symlinks:"
    if [[ -d "analysis/paper" ]]; then
        cd analysis/paper
        remove_symlink "figures" "  figures/"
        remove_symlink "media" "  media/"
        remove_symlink "data" "  data/"
        cd ../..
    fi

    echo ""
    success "Symlinks removed"
}

# Show symlink status
show_status() {
    info "Blog post symlink status:"
    echo ""

    echo "Root-level:"
    for link in index.qmd figures media data; do
        if [[ -L "$link" ]]; then
            local target
            target=$(readlink "$link")
            echo -e "  ${GREEN}✓${NC} $link → $target"
        elif [[ -e "$link" ]]; then
            echo -e "  ${YELLOW}⚠${NC} $link (exists but not a symlink)"
        else
            echo -e "  ${RED}✗${NC} $link (missing)"
        fi
    done

    echo ""
    echo "analysis/paper/:"
    if [[ -d "analysis/paper" ]]; then
        cd analysis/paper
        for link in figures media data; do
            if [[ -L "$link" ]]; then
                local target
                target=$(readlink "$link")
                echo -e "  ${GREEN}✓${NC} $link → $target"
            elif [[ -e "$link" ]]; then
                echo -e "  ${YELLOW}⚠${NC} $link (exists but not a symlink)"
            else
                echo -e "  ${RED}✗${NC} $link (missing)"
            fi
        done
        cd ../..
    else
        echo -e "  ${RED}✗${NC} analysis/paper/ directory doesn't exist"
    fi
}

# Show help
show_help() {
    cat << 'EOF'
Blog Post Symlink Setup for ZZCOLLAB

USAGE:
    ./setup_symlinks.sh [OPTION]

OPTIONS:
    (no args)    Create symlinks for blog post structure
    --remove     Remove blog post symlinks
    --status     Show current symlink status
    --help       Show this help message

DESCRIPTION:
    This script creates a dual symlink structure that allows:

    1. Quarto to find index.qmd at the post root (required by Quarto blogs)
    2. HTML to resolve paths like figures/plot.png from the post root
    3. Intuitive editing in analysis/paper/ with simple relative paths

STRUCTURE CREATED:
    post_root/
    ├── index.qmd → analysis/paper/index.qmd   (for Quarto)
    ├── figures/  → analysis/figures/           (for HTML)
    ├── media/    → analysis/media/             (for HTML)
    ├── data/     → analysis/data/              (for HTML)
    └── analysis/
        ├── paper/
        │   ├── index.qmd                       (actual file)
        │   ├── figures/ → ../figures/          (for editing)
        │   ├── media/   → ../media/            (for editing)
        │   └── data/    → ../data/             (for editing)
        ├── figures/                            (actual R-generated plots)
        ├── media/
        │   ├── images/                         (static images)
        │   ├── audio/                          (audio files)
        │   └── video/                          (video files)
        └── data/
            ├── raw_data/
            └── derived_data/

USAGE IN index.qmd:
    After setup, write paths relative to analysis/paper/:

    ![Plot](figures/plot.png)
    ![Hero](media/images/hero.jpg)

    These resolve correctly both when editing and in rendered HTML.

EXAMPLES:
    # Set up blog post structure
    cd posts/my_blog_post
    modules/setup_symlinks.sh

    # Check status
    modules/setup_symlinks.sh --status

    # Remove symlinks (revert to standard structure)
    modules/setup_symlinks.sh --remove

SEE ALSO:
    vignettes/workflow-blog-development.Rmd - Complete blog workflow guide
EOF
}

# Main
main() {
    case "${1:-}" in
        --remove)
            check_project_root
            remove_symlinks
            ;;
        --status)
            check_project_root
            show_status
            ;;
        --help|-h)
            show_help
            ;;
        "")
            check_project_root
            create_symlinks
            ;;
        *)
            error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
}

main "$@"
