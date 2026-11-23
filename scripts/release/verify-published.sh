#!/usr/bin/env bash
#
# Sourced by render-formulae.sh, which calls verify_published for `--verify-published`. It is not run by itself.
#
# Read what is published instead of rendering it. For every formula in Formula/ and every asset it names, the release
# the url names has its SHA256SUMS and signature verified exactly as a render verifies them (verify_sha256sums), and the
# digest in the formula has to be the entry of the asset the url names (hash_of). A render writes only digests it
# verified, but a formula is a file a person can edit, and nothing after the render read it against the signed list
# again: the digest of an asset nobody signed (a file added to a release by someone who cannot forge the signature)
# passes every other gate, because the bytes behind the url really do have that digest. published-bytes.yml runs it.
#
# A release is verified once per product, however many assets name it: its SHA256SUMS and signatures are three
# transfers, and a second read of the same release learns nothing the first did not. The product is part of the key
# because the verdict depends on it (a product the required list names must carry the second signature). The signed
# list is kept and put back before each digest is read, so every asset is still compared against the list of the
# release its url names, and a release that was refused is refused for every asset that names it.
#
# Exit 0 when every digest is the signed one, 1 otherwise. A tap with no formula is a failure: nothing was verified.
#
# It takes the folder of the tap and the working folder as its two arguments, and needs what the renderer defines:
# PRODUCTS, verify_sha256sums, hash_of and verify_attestation (which reads $base, given to it for the release of each url
# in the assignment that precedes the call). The job that runs it needs a read-only GH_TOKEN for `gh attestation verify`,
# and nothing else.
verify_published() { # $1=the folder of the tap $2=the working folder
	local root="$1" work="$2"
	local formula name repo row row_repo row_formula url digest prefix rest tag asset signed
	local checked=0 failed=0 key lists=0
	local -A release_list=()
	shopt -s nullglob
	for formula in "$root"/Formula/*.rb; do
		name="$(basename "$formula" .rb)"
		repo=""
		for row in "${PRODUCTS[@]}"; do
			IFS='|' read -r row_repo row_formula _ <<<"$row"
			[ "$row_formula" != "$name" ] || repo="$row_repo"
		done
		if [ -z "$repo" ]; then
			echo "::error file=$formula::the PRODUCTS table has no row for \"$name\", so its digests cannot be read against a signed release" >&2
			failed=$((failed + 1))
			continue
		fi
		prefix="https://github.com/$repo/releases/download/"
		while IFS=$'\t' read -r url digest; do
			checked=$((checked + 1))
			case "$url" in
				"$prefix"*) rest="${url#"$prefix"}" ;;
				*)
					echo "::error file=$formula::$url is not an asset of $repo" >&2
					failed=$((failed + 1))
					continue
					;;
			esac
			tag="${rest%%/*}"
			asset="${rest#*/}"
			case "$asset" in
				"" | */*)
					echo "::error file=$formula::$url is not one asset of one release" >&2
					failed=$((failed + 1))
					continue
					;;
			esac
			key="$repo|$tag|$name"
			if [ -z "${release_list[$key]:-}" ]; then
				if verify_sha256sums "$repo" "$tag" "$name"; then
					lists=$((lists + 1))
					cp "$work/SHA256SUMS" "$work/signed.$lists"
					release_list["$key"]="$work/signed.$lists"
				else
					release_list["$key"]="refused"
				fi
			fi
			if [ "${release_list[$key]}" = refused ]; then
				echo "::error file=$formula::$url names $repo $tag, whose release was not admitted" >&2
				failed=$((failed + 1))
				continue
			fi
			cp "${release_list[$key]}" "$work/SHA256SUMS"
			signed="$(hash_of "$asset")" || {
				echo "::error file=$formula::$url downloads $asset, which the signed SHA256SUMS of $repo $tag does not list once" >&2
				failed=$((failed + 1))
				continue
			}
			if [ "$signed" != "$digest" ]; then
				echo "::error file=$formula::$url declares digest $digest, but the signed SHA256SUMS of $repo $tag gives $signed for $asset" >&2
				failed=$((failed + 1))
				continue
			fi
			# A signed list authenticates its own bytes, not the tag it was made for: an old SHA256SUMS with its valid
			# signature and its binaries can be published again under a new tag. The attestation of the binary is what
			# ties it to refs/tags/<tag> and to the release workflow, as the render checks it for every asset.
			base="https://github.com/$repo/releases/download/$tag" verify_attestation "$repo" "$tag" "$asset" "$signed" || {
				echo "::error file=$formula::$url: the build provenance of $asset is missing, names another tag than $tag, or was not signed by the release workflow of $repo" >&2
				failed=$((failed + 1))
			}
		done < <(awk '
			/^[[:space:]]*url "/ { if (pending) print url "\t"; url = $0; sub(/^[^"]*"/, "", url); sub(/".*$/, "", url); pending = 1; next }
			pending { digest = ""; if ($0 ~ /^[[:space:]]*sha256 "/) { digest = $0; sub(/^[^"]*"/, "", digest); sub(/".*$/, "", digest) } print url "\t" digest; pending = 0 }
			END { if (pending) print url "\t" }
		' "$formula")
	done
	if [ "$checked" -eq 0 ]; then
		echo "::error::no digest was read against a signed release" >&2
		return 1
	fi
	if [ "$failed" -ne 0 ]; then
		echo "::error::$failed of $checked published digest(s) are not the ones the signed SHA256SUMS gives" >&2
		return 1
	fi
	echo "verified $checked published digest(s) against the signed SHA256SUMS"
}
