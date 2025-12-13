# zzedcindependence

> **zzcollab research compendium** | [Framework Documentation](https://github.com/rgt47/zzcollab)

## Overview

This ZZCOLLAB research compendium contains the blog post **"Taking Control of Your Clinical Trial: Running ZZedc Independently"** - a comprehensive guide for investigators who want to own and operate their own open-source electronic data capture system.

**Blog Post**: [analysis/paper/index.qmd](analysis/paper/index.qmd)

**Blog Topics**:
- The independence problem: Why control matters in clinical research
- ZZedc overview: Open-source EDC platform for investigator ownership
- Deployment paths: From laptop to multi-site AWS infrastructure
- Technical architecture and security
- Step-by-step implementation guides
- Long-term sustainability and data stewardship

**Status**: Published
**License**: GPL-3
**Date**: 2025-12-07
**Last Updated**: 2025-12-08

---

## Quick Start for Team Members

### Prerequisites

Install the zzcollab framework:

```bash
git clone https://github.com/rgt47/zzcollab.git
cd zzcollab
./install.sh
```

### Join This Project

```bash
# Clone the repository
git clone https://github.com/rgt47/zzedcindependence.git
cd zzedcindependence

# Pull team Docker image and setup
zzcollab -u

# Start development environment
make docker-zsh
```

---

## Project Structure

This project follows the [rrtools](https://github.com/benmarwick/rrtools) research compendium structure:

```
zzedcindependence/
├── analysis/
│   ├── data/
│   │   ├── raw_data/       # Original, unmodified data
│   │   └── derived_data/   # Processed, analysis-ready data
│   ├── scripts/            # Analysis code
│   ├── paper/              # Manuscript (paper.Rmd)
│   ├── figures/            # Generated visualizations
│   └── templates/          # Analysis templates
├── R/                      # Reusable R functions
├── tests/                  # Unit tests
├── DESCRIPTION             # Package metadata
├── Dockerfile              # Computational environment
└── renv.lock              # Package versions (reproducibility)
```

---

## Development Workflow

### Daily Development

```bash
# 1. Enter development container
make docker-zsh

# 2. Work in R (packages auto-captured on exit)
library(tidyverse)
# ... your analysis ...

# 3. Exit container (automatic snapshot)
q()

# 4. Test and commit
make docker-test
git add .
git commit -m "Add analysis"
git push
```

### Common Tasks

```bash
make docker-zsh          # Start interactive R session
make docker-rstudio      # Start RStudio Server (localhost:8787)
make docker-test         # Run all tests
make docker-build        # Build Docker image
make docker-push-team    # Push team image to Docker Hub
make check-renv          # Validate package dependencies
```

### Navigation Shortcuts (Optional)

Install one-letter navigation shortcuts for faster workflow:

```bash
# Install navigation functions
./navigation_scripts.sh --install

# Now you can jump to directories from anywhere in the project:
r     # → project root
a     # → analysis/
s     # → analysis/scripts/
p     # → analysis/paper/
f     # → analysis/figures/
d     # → data/
nav   # → list all shortcuts
```

### Getting Help

The zzcollab framework has a comprehensive git-like help system:

```bash
# Brief overview
zzcollab                     # Show common workflows
zzcollab help                # Same

# Specific topics
zzcollab help quickstart     # Solo developer guide
zzcollab help workflow       # Daily development
zzcollab help team           # Team collaboration
zzcollab help config         # Configuration
zzcollab help docker         # Docker details
zzcollab help renv           # Package management

# List all topics
zzcollab help --all

# Legacy format (full options)
zzcollab --help
```

**Help Topics**:
- **Guides**: quickstart, workflow, team
- **Configuration**: config, profiles, examples
- **Technical**: docker, renv, cicd
- **Other**: options, troubleshoot

---

## Reproducibility

This project ensures reproducibility through five version-controlled components:

1. **Dockerfile** - Computational environment (R version, system dependencies)
2. **renv.lock** - Exact R package versions
3. **.Rprofile** - R session configuration
4. **Source code** - Analysis scripts and functions
5. **Data** - Raw and derived datasets

Any researcher can reproduce this analysis by:

```bash
git clone https://github.com/rgt47/zzedcindependence.git
cd zzedcindependence
zzcollab -u
make docker-zsh
# Analysis runs in identical environment
```

---

## Documentation

- **Analysis Data**: See `analysis/data/README.md` for data documentation
- **Development Guide**: See `docs/` for detailed technical documentation
- **zzcollab Framework**: See [zzcollab docs](https://github.com/rgt47/zzcollab)

---

## Citation

**Blog Post**: Taking Control of Your Clinical Trial: Running ZZedc Independently
**Author**: Clinical Research Technology
**Published**: December 7, 2025
**Source**: [qblog - Clinical Research Technology Blog](https://github.com/rgt47/qblog)

To cite this blog post:
```
Clinical Research Technology. (2025). Taking Control of Your Clinical Trial:
Running ZZedc Independently. Retrieved from
https://github.com/rgt47/qblog/posts/zzedc_independence/
```

---

## License

This project is licensed under the GNU General Public License v3.0 (GPL-3).

### Summary

- ✅ You can use, modify, and distribute this code
- ✅ You must share modifications under GPL-3
- ✅ You must include license and copyright notice
- ❌ No warranty provided

**Full license**: See [LICENSE](LICENSE) file or https://www.gnu.org/licenses/gpl-3.0.en.html

---

## Contact

**Blog Author**: Clinical Research Technology Team
**Blog Repository**: [qblog](https://github.com/rgt47/qblog)
**ZZedc Project**: For questions about ZZedc implementation, visit the ZZedc documentation

---

## Acknowledgments

This research compendium was created using [zzcollab](https://github.com/rgt47/zzcollab),
a framework for reproducible computational research.

<!--
TODO: Add acknowledgments for funding, collaborators, data sources, etc.
-->
