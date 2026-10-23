#!/usr/bin/env bash
#
# format - reformat every source ./lint.sh checks, with the exact formatters
# and flags ./lint.sh verifies against:
#
#   format sh:     shfmt -w -s -i 0 -bn -ci -sr (*.sh)
#   format md:     prettier --write --end-of-line lf (*.md; falls back to
#                  npx like ./lint.sh's check does)
#   format yaml:   yamlfmt -o=kyaml output written back byte for byte
#                  (*.yml/*.yaml; ./lint.sh compares the repo files to
#                  exactly this profile)
#   format Docker: dockerfmt -s -n -w (*Dockerfile*)
#   format Make:   mbake format --config .bake.toml (Makefile)
#
# Written to be run directly on a host with the lint toolset. `make format`
# runs this same script inside the same fedora container as `make lint`, so
# no local installs are needed there.
#
# Heredoc bodies are excluded on purpose: the YAML/sh/awk/HAPROXY bodies
# inside *.sh and the Dockerfile RUN body are hand-maintained, and only
# ./lint.sh knows what each must contain. `format` rewrites whole files
# only; run ./lint.sh afterwards to verify every heredoc check still
# passes.
#
# Files come from git like ./lint.sh's discovery: tracked plus not-yet-
# ignored untracked files, so new files are formatted too. Tools run in
# their strictest live mode (-w/--write); nothing is diffed or checked
# here, ./lint.sh is the source of truth for what canonical output is.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# No arguments: formatting rewrites files, so a stray argument (a typo'd
# glob, a forgotten remove) must not be silently ignored.
if [[ $# -ne 0 ]]; then
	printf '[format] usage: %s (takes no arguments)\n' "${0}" >&2
	exit 1
fi

# Tracked plus not-yet-gitignored files, so new files are formatted too.
# git's failure must be loud, otherwise an empty list would silently skip
# every category below.
git_list() { # pathspec...
	local out
	out=$(git ls-files --cached --others --exclude-standard -- "$@") || {
		printf '[format] git ls-files failed (run inside a git checkout)\n' >&2
		return 1
	}
	printf '%s' "${out}"
}
sh_list=$(git_list '*.sh')
md_list=$(git_list '*.md')
yaml_list=$(git_list '*.yml' '*.yaml')
docker_list=$(git_list '*Dockerfile*')
make_list=$(git_list 'Makefile')
sh_files=() md_files=() yaml_files=() docker_files=() make_files=()
# mapfile one kind at a time: a kind the repo has none of must yield an
# empty array (a bare `[[ -n ... ]] && mapfile` would abort the whole run
# under set -e), and the per-kind blocks below skip empty arrays anyway.
if [[ -n ${sh_list} ]]; then
	mapfile -t sh_files <<< "${sh_list}"
fi
if [[ -n ${md_list} ]]; then
	mapfile -t md_files <<< "${md_list}"
fi
if [[ -n ${yaml_list} ]]; then
	mapfile -t yaml_files <<< "${yaml_list}"
fi
if [[ -n ${docker_list} ]]; then
	mapfile -t docker_files <<< "${docker_list}"
fi
if [[ -n ${make_list} ]]; then
	mapfile -t make_files <<< "${make_list}"
fi

# prettier: local binary if present, otherwise the latest via npx (CI
# relies on this npx fallback, so no global npm install is needed).
if command -v prettier > /dev/null 2>&1; then
	prettier_cmd=(prettier)
elif command -v npx > /dev/null 2>&1; then
	prettier_cmd=(npx --yes prettier@latest)
else
	printf '[format] missing tool: prettier (install prettier or node/npx)\n' >&2
	exit 1
fi

for tool in shfmt dockerfmt yamlfmt mbake; do
	command -v "${tool}" > /dev/null 2>&1 || {
		printf '[format] missing tool: %s\n' "${tool}" >&2
		exit 1
	}
done

# yamlfmt -w rewrites files through a temporary file, so inside `make
# format`'s root-owned container every rewritten file would end up root
# owned with 0600 mode (the other formatters truncate the existing file and
# keep its inode, owner and mode). Formatting to stdout first - the same
# call ./lint.sh checks against - and truncating in place keeps every
# byte, mode and ownership of the file itself; an unparsable file fails
# before its content is touched.
format_yaml() { # files...
	local yaml_file out
	for yaml_file in "$@"; do
		if ! out=$(yamlfmt -o=kyaml "${yaml_file}" 2>&1); then
			printf '%s: not parseable as YAML:\n%s\n' "${yaml_file}" "${out}" >&2
			return 1
		fi
		printf '%s\n' "${out}" > "${yaml_file}"
	done
}

if [[ ${#sh_files[@]} -gt 0 ]]; then
	shfmt -w -s -i 0 -bn -ci -sr "${sh_files[@]}"
fi
if [[ ${#md_files[@]} -gt 0 ]]; then
	"${prettier_cmd[@]}" --write --end-of-line lf "${md_files[@]}"
fi
if [[ ${#yaml_files[@]} -gt 0 ]]; then
	format_yaml "${yaml_files[@]}"
fi
if [[ ${#docker_files[@]} -gt 0 ]]; then
	dockerfmt -s -n -w "${docker_files[@]}"
fi
if [[ ${#make_files[@]} -gt 0 ]]; then
	mbake format --config .bake.toml "${make_files[@]}"
fi
