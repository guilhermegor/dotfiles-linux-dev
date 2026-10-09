#!/bin/bash
# Installs personal skill files into ~/.claude/skills/<name>/SKILL.md.
# Skills are markdown files loaded by Claude's Skill tool mid-task,
# distinct from slash commands which are user-invoked.
#
# Source stays flat (skills/<name>.md); only the install target is a directory,
# because that is the only layout Claude Code's skill loader discovers.

# shellcheck source=../hooks/lib/dotfiles_dir.sh
source "$(dirname "${BASH_SOURCE[0]}")/../hooks/lib/dotfiles_dir.sh"

install_skills() {
    print_status "section" "INSTALLING USER SKILLS"

    local skills_src="$SCRIPT_DIR/skills"
    local skills_dst="$CLAUDE_DIR/skills"

    if [[ ! -d "$skills_src" ]]; then
        print_status "warning" "No skills source directory found at $skills_src — skipping"
        return 0
    fi

    mkdir -p "$skills_dst"

    # Sweep the pre-<name>/SKILL.md layout: flat *.md at the skills root are never
    # loadable, so any left here are dead copies from an older install. Root-level
    # only — the glob cannot reach the <name>/SKILL.md directories below.
    local stale
    stale=$(find "$skills_dst" -maxdepth 1 -type f -name '*.md' -delete -print | wc -l)
    (( stale > 0 )) && print_status "info" "Removed $stale stale flat skill file(s)"

    local installed=0

    for skill_file in "$skills_src"/*.md; do
        [[ -e "$skill_file" ]] || continue  # glob matched nothing

        local slug
        slug="$(basename "$skill_file" .md)"
        # Claude Code discovers skills as <name>/SKILL.md — a flat <name>.md is
        # copied successfully but never loaded.
        local dst="$skills_dst/$slug/SKILL.md"

        mkdir -p "$skills_dst/$slug"
        install_with_dotfiles_dir "$skill_file" "$dst" || return 1
        print_status "success" "Installed skill: $slug → $dst"
        (( ++installed ))
    done

    if (( installed == 0 )); then
        print_status "info" "No skill files found in $skills_src"
    else
        print_status "info" "Installed $installed skill(s) to $skills_dst"
    fi
}
