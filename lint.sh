#!/usr/bin/env bash
#
# lint - format/lint checks for every sh, Dockerfile, markdown and YAML
# file in the repo. CI runs this same script (.github/workflows/lint.yml).
# All tools run in their strictest mode:
#
#   format sh:         shfmt -l -s -d   (list + simplify + diff)
#   lint sh:           shellcheck -o all -x   (all optional checks + follow sources)
#   format md/yaml:    prettier --check --end-of-line lf
#   format Dockerfile: dockerfmt -s -n --check   (space redirects + trailing newline)
#
# Fix locally with:  shfmt -w -s <files>  |  prettier --write <files>  |
#                    dockerfmt -w Dockerfile
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

status=0
check() { # desc cmd...
	local desc=$1
	shift
	if "$@"; then
		printf 'ok   %s\n' "${desc}"
	else
		printf 'FAIL %s\n' "${desc}"
		status=1
	fi
}

for tool in shfmt shellcheck dockerfmt; do
	command -v "${tool}" >/dev/null 2>&1 || {
		printf '[lint] missing tool: %s (install it to run this check)\n' "${tool}" >&2
		exit 1
	}
done

# prettier: local binary if present, otherwise the latest version via npx
# (CI relies on this npx fallback, so no global npm install is needed).
if command -v prettier >/dev/null 2>&1; then
	prettier_cmd=(prettier)
elif command -v npx >/dev/null 2>&1; then
	prettier_cmd=(npx --yes prettier)
else
	printf '[lint] missing tool: prettier (install prettier or node/npx)\n' >&2
	exit 1
fi

# Tracked plus not-yet-gitignored files, so new files are checked too.
# git's failure must be loud, otherwise an empty list would silently skip
# every check below.
git_list() { # pathspec...
	local out
	out=$(git ls-files --cached --others --exclude-standard -- "$@") || {
		printf '[lint] git ls-files failed (run inside a git checkout)\n' >&2
		return 1
	}
	printf '%s' "${out}"
}
sh_list=$(git_list '*.sh')
fmt_list=$(git_list '*.md' '*.yml' '*.yaml')
docker_list=$(git_list 'Dockerfile*' '*Dockerfile*')
sh_files=() fmt_files=() docker_files=()
[[ -n ${sh_list} ]] && mapfile -t sh_files <<<"${sh_list}"
[[ -n ${fmt_list} ]] && mapfile -t fmt_files <<<"${fmt_list}"
[[ -n ${docker_list} ]] && mapfile -t docker_files <<<"${docker_list}"

if [[ ${#sh_files[@]} -gt 0 ]]; then
	check "shfmt -l -s (${#sh_files[@]} sh)" shfmt -l -s -d "${sh_files[@]}"
	check "shellcheck -o all -x (${#sh_files[@]} sh)" shellcheck -o all -x "${sh_files[@]}"
fi
if [[ ${#fmt_files[@]} -gt 0 ]]; then
	check "prettier (${#fmt_files[@]} md/yaml)" "${prettier_cmd[@]}" --check --end-of-line lf "${fmt_files[@]}"
fi
if [[ ${#docker_files[@]} -gt 0 ]]; then
	for f in "${docker_files[@]}"; do
		check "dockerfmt -s -n (${f})" dockerfmt -s -n --check "${f}"
	done
fi

if [[ ${status} -ne 0 ]]; then
	printf '\n[lint] FAILED - see the tool output above for the offending files\n' >&2
fi
exit "${status}"
