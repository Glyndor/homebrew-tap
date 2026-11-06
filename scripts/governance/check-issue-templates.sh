#!/usr/bin/env bash
#
# scripts/governance/check-issue-templates.sh -- the issue templates must ask for
# the platform this channel installs on, and for an install method that exists
# here.
#
# The bug report template is the first thing a user meets when something breaks.
# It asks two questions -- which operating system, and which version and how did
# you install it -- and both have to be answerable in this channel, or the
# reporter writes something the maintainer cannot use.
#
# The template was copied from another channel and never adapted. It offered
# "e.g. Ubuntu 24.04, Debian 13, Fedora 42" as the operating system and
# "v0.3.1 (install.sh)" as the version. Neither belongs here: this channel
# installs with `brew install glyndor/tap/<product>` and runs on macOS, and
# `install.sh` is a script in the product repositories, not in this one. The
# field is required, so the reporter had to answer it, with the wrong example in
# front of them.
#
# The install command is not written down here. It is read out of the README's
# own Install section, and the product it names is checked against the files
# this channel actually serves, so the template cannot drift away from the
# command the README documents without this going red.
#
# What it refuses, and what it says in each case:
#
#   * an operating system field that does not name this channel's platform
#   * an operating system field that names a platform this channel does not serve
#   * an operating system field that does not ask for the package manager's
#     version, which is half of what tells one installation from another
#   * a version field that does not name the install command the README
#     documents
#   * a template that names an install method this channel does not have
#
# And it fails loudly when it cannot read what it needs: a template without
# those two fields, a README without an install command, a channel with no
# product files. A checker that cannot read the answer reports nothing, and
# nothing reads as agreement.
#
# Usage: check-issue-templates.sh [repo-root]   (default: the repo this lives in)

set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# --- this channel's facts ----------------------------------------------------
#
# The platform a reporter is on, and the directory whose files are what
# `brew install` puts on the machine: one file per product.
platform="macOS"
artifact_dir="Formula"

# The install methods of the product repositories. They exist there and not
# here, and naming one in this channel's template sends the reporter looking
# for a file that was never published.
foreign_methods="install.sh install.ps1"

# The distributions that are not a platform this channel serves. This tap
# serves Linux too (see README.md), so the list is empty: a distribution named
# next to macOS is not wrong here, and refusing it would forbid the answer a
# Homebrew-on-Linux user has to give.
other_platforms=""

template="$root/.github/ISSUE_TEMPLATE/bug_report.yml"
readme="$root/README.md"

status=0
error() { echo "::error::$1" >&2; status=1; }

for required in "$template" "$readme"; do
	if [ ! -f "$required" ]; then
		echo "::error::no ${required#"$root"/} under $root" >&2
		exit 1
	fi
done

# The text of one field of the template: from the line that carries the field's
# id up to the line before the next field starts. The body is a list of items,
# each one opening with "- type:", so that is the boundary.
field_text() { # $1=field id
	awk -v want="$1" '
		$0 ~ ("id:[[:space:]]*" want "[[:space:]]*$") { inside = 1 }
		inside && /^[[:space:]]*-[[:space:]]*type:/ { exit }
		inside { print }
	' "$template"
}

# The install commands the README documents: the first fenced block under its
# Install heading.
readme_install_lines() {
	awk '
		/^## Install/ { section = 1; next }
		/^## / { section = 0 }
		section && /^```/ { if (fence) exit; fence = 1; next }
		section && fence { print }
	' "$readme"
}

# The products this channel serves: one file per product under the artifact
# directory, named after it.
products="$(find "$root/$artifact_dir" -maxdepth 1 -type f \
	\( -name '*.rb' -o -name '*.json' \) -printf '%f\n' 2>/dev/null \
	| sed 's/\.[^.]*$//' | LC_ALL=C sort -u)"

os_field="$(field_text os)"
version_field="$(field_text version)"

if [ -z "$os_field" ]; then
	error "the bug report template has no field with id 'os'"
fi
if [ -z "$version_field" ]; then
	error "the bug report template has no field with id 'version'"
fi
if [ -z "$products" ]; then
	error "no product files under $artifact_dir, so there is nothing to check the install command against"
fi

# The install command is the line of the README's Install block that names a
# product this channel serves. The block holds more than one line -- adding a
# bucket, installing a prerequisite -- and only one of them installs a product
# of ours.
install_command=""
while IFS= read -r line; do
	[ -n "$line" ] || continue
	for product in $products; do
		case "$line" in
			*"$product"*) install_command="$line"; break 2 ;;
		esac
	done
done <<EOF
$(readme_install_lines)
EOF

if [ -z "$install_command" ]; then
	error "no install command for a served product in the README's Install section"
fi

# The package manager is the first word of that command: brew here, scoop in
# the sibling channel.
manager="${install_command%% *}"

# Whether the text holds the install command as a whole command and not as the
# beginning of a longer one: "brew install glyndor/tap/podup" is in
# "e.g. 5.16.0 (brew install glyndor/tap/podup)" and is not in
# "brew install glyndor/tap/podup-nightly".
holds_install_command() { # $1=text
	local escaped
	escaped="$(printf '%s' "$install_command" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
	printf '%s\n' "$1" | grep -qE "(^|[^A-Za-z0-9_.-])${escaped}([^A-Za-z0-9_.-]|$)"
}

if [ -n "$os_field" ]; then
	if ! printf '%s\n' "$os_field" | grep -qiF "$platform"; then
		error "the operating system field does not name $platform, a platform this channel serves"
	fi
	if [ -n "$manager" ] && ! printf '%s\n' "$os_field" | grep -qiF "$manager"; then
		error "the operating system field does not ask for the $manager version"
	fi
	for other in $other_platforms; do
		if printf '%s\n' "$os_field" | grep -qiwF "$other"; then
			error "the operating system field names $other, which is not the platform this channel installs on"
		fi
	done
fi

if [ -n "$version_field" ] && [ -n "$install_command" ]; then
	if ! holds_install_command "$version_field"; then
		error "the version field does not name the install command the README documents: $install_command"
	fi
fi

for method in $foreign_methods; do
	if grep -qF "$method" "$template"; then
		error "the template names $method, which this channel does not have"
	fi
done

if [ "$status" -ne 0 ]; then
	echo "the issue templates do not match this channel" >&2
	exit 1
fi

echo "ok  the bug report template asks for $platform and names: $install_command"
