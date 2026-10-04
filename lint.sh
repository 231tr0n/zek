#!/usr/bin/env bash
#
# lint - format/lint checks for every sh, Dockerfile, markdown and YAML
# file in the repo. CI runs this same script (.github/workflows/lint.yml).
# All tools run in their strictest mode:
#
#   format sh:          shfmt -l -s -d   (list + simplify + diff)
#   lint sh:            shellcheck -o all -x   (all optional checks + follow sources)
#   lint sh directives: every '# shellcheck disable=' line must still be
#                       required - the directive is stripped and shellcheck
#                       must then report an issue
#   lint sh manifests:  every EOF heredoc must round-trip through
#                       sigs.k8s.io/yaml/yamlfmt -o=yaml unchanged (k8s
#                       manifests, parsed the way the shell expands them;
#                       block profile because kubeadm's config decoder
#                       sniffs flow-style kyaml as strict JSON and fails,
#                       so every heredoc stays in the format kubeadm
#                       accepts - whether or not this one feeds it)
#   lint sh lb config:  the HAPROXY heredocs are assembled over stdin with
#                       one synthetic backend server, checked with
#                       haproxy -c -f /dev/stdin, and style-checked for
#                       tab-only indentation and trailing whitespace
#   format md:          prettier --check --end-of-line lf
#   format yaml:        yamlfmt (kyaml profile, compared byte for byte)
#   format Dockerfile:  dockerfmt -s -n --check   (space redirects + trailing newline)
#
# Checks run in parallel; every tool reads its payload over stdin (no
# intermediate files - only the ordered per-check report buffers).
#
# Fix locally with:  shfmt -w -s <files>  |  prettier --write <files>  |
#                    dockerfmt -w Dockerfile  |  yamlfmt -w <files>  |
#                    dnf install haproxy  |
#                    go install sigs.k8s.io/yaml/yamlfmt@latest
#
# The check functions only ever run through run_check's dynamic dispatch
# (their names are passed as arguments), so SC2329 - the unused-function
# check - is disabled for this file below.
# shellcheck disable=SC2329
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

status=0

# Every check runs in the background with its own output buffer so the
# report keeps launch order while the tools still run in parallel.
check_pids=() check_bufs=()
run_check() { # desc cmd...
	local desc=$1 buf
	shift
	buf=$(mktemp)
	check_bufs+=("${buf}")
	{
		if "$@"; then
			printf 'ok   %s\n' "${desc}"
		else
			printf 'FAIL %s\n' "${desc}"
			exit 1
		fi
	} >"${buf}" 2>&1 &
	check_pids+=("$!")
}
wait_checks() {
	local i
	for i in "${!check_pids[@]}"; do
		wait "${check_pids[i]}" || status=1
		cat "${check_bufs[i]}"
		rm -f "${check_bufs[i]}"
	done
	check_pids=() check_bufs=()
}

for tool in shfmt shellcheck dockerfmt yamlfmt; do
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

# The LB config checks need a haproxy binary; its absence fails lint but
# does not short-circuit the other checks.
haproxy_tool=1
if ! command -v haproxy >/dev/null 2>&1; then
	printf '[lint] missing tool: haproxy (dnf install haproxy / apt install haproxy)\n' >&2
	status=1
	haproxy_tool=0
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
md_list=$(git_list '*.md')
yaml_list=$(git_list '*.yml' '*.yaml')
docker_list=$(git_list 'Dockerfile*' '*Dockerfile*')
sh_files=() md_files=() yaml_files=() docker_files=()
[[ -n ${sh_list} ]] && mapfile -t sh_files <<<"${sh_list}"
[[ -n ${md_list} ]] && mapfile -t md_files <<<"${md_list}"
[[ -n ${yaml_list} ]] && mapfile -t yaml_files <<<"${yaml_list}"
[[ -n ${docker_list} ]] && mapfile -t docker_files <<<"${docker_list}"

# awk program printing one heredoc body to stdout: -s is the opener line,
# -d the delimiter line, -u=1 for quoted openers (no shell escaping to
# strip; an unquoted heredoc's \$ is a literal dollar for the shell, so
# the YAML parser must see plain $).
body_awk=$(
	cat <<'AWK'
	NR > s && $0 == d { exit }
	NR > s { line = $0; if (u == 0) gsub(/\\\$/, "$", line); print line }
AWK
)

# list_heredocs DELIM SRC... - emit one "src:line:quoted" marker per
# closed heredoc with that delimiter. Mirrors the shell: comment lines are
# never openers (bash ignores them), a here-string (<<<) can never match,
# and the terminator line must equal the delimiter exactly.
list_heredocs() {
	local delim=$1 src
	shift
	for src in "$@"; do
		awk -v delim="${delim}" -v src="${src}" '
			/^[ \t]*#/ && !inbody { next }
			!inbody {
				if (match($0, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*/)) {
					m = substr($0, RSTART, RLENGTH)
					name = m
					sub(/^<<-?[ \t]*[\047"]?/, "", name)
					sub(/[\047"]+$/, "", name)
					q = (m ~ /[\047"]/)
					curdelim = name
					istarget = (name == delim)
					inbody = 1
					start = FNR
				}
				next
			}
			{
				if ($0 == curdelim) {
					if (istarget) printf "%s:%d:%d\n", src, start, q
					inbody = 0
				}
			}
			END {
				if (inbody) {
					printf "unterminated heredoc: %s:%d\n", src, start > "/dev/stderr"
					exit 1
				}
			}
		' "${src}"
	done
}

# Every EOF heredoc body must be canonical block-style yamlfmt output:
# parse it exactly as the shell would present it and require yamlfmt
# -o=yaml to reproduce it byte for byte (a parse error or any diff fails).
lint_heredocs_yaml() {
	local src start quoted body canon rc=0
	# shellcheck disable=SC2312  # marker stream is the loop's input by design
	while IFS=: read -r src start quoted; do
		if ! body=$(awk -v s="${start}" -v d=EOF -v u="${quoted}" "${body_awk}" "${src}"); then
			printf '%s:%s: cannot read heredoc body\n' "${src}" "${start}" >&2
			rc=1
			continue
		fi
		[[ -n ${body} ]] || continue
		if ! canon=$(printf '%s\n' "${body}" | yamlfmt -o=yaml 2>&1); then
			printf '%s:%s: not parseable as YAML for formatting:\n%s\n' \
				"${src}" "${start}" "${canon}" >&2
			rc=1
			continue
		fi
		if [[ ${body} != "${canon}" ]]; then
			printf '%s:%s: heredoc is not canonical yamlfmt block output (diff: - source, + yamlfmt -o=yaml):\n' \
				"${src}" "${start}" >&2
			diff <(printf '%s\n' "${body}") <(printf '%s\n' "${canon}") | sed 's/^/  /' >&2 || true
			rc=1
		fi
	done < <(list_heredocs EOF "$@")
	return "${rc}"
}

# Every '# shellcheck disable=' directive must be required: strip the line
# and let shellcheck decide. shellcheck reads the file over stdin (the
# shebang in the stream picks the dialect), so nothing hits the disk; an
# expected problem is silenced, a passing run is the violation.
lint_shellcheck_directives() {
	local f l rc=0
	for f in "$@"; do
		while IFS=: read -r l _; do
			[[ -n ${l} ]] || continue
			if sed "${l}d" "${f}" | shellcheck -o all -x - >/dev/null 2>&1; then
				printf '%s:%s: unnecessary shellcheck disable (shellcheck passes without it)\n' \
					"${f}" "${l}" >&2
				rc=1
			fi
		done < <(grep -nE '^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+disable=' "${f}" || true)
	done
	return "${rc}"
}

# assemble_haproxy SRC... - print the complete LB config: the HAPROXY
# heredoc bodies in order, with one synthetic backend server line between
# them (run_lb prints a real one per control-plane IP at runtime).
assemble_haproxy() {
	local src start quoted body first=1
	# shellcheck disable=SC2312  # marker stream is the loop's input by design
	while IFS=: read -r src start quoted; do
		if ! body=$(awk -v s="${start}" -v d=HAPROXY -v u="${quoted}" "${body_awk}" "${src}"); then
			printf 'cannot read HAPROXY heredoc %s:%s\n' "${src}" "${start}" >&2
			return 1
		fi
		if [[ ${first} -eq 1 ]]; then
			first=0
		else
			printf '\tserver cp1 127.0.0.1:6443 check inter 2s fall 3 rise 2\n'
		fi
		printf '%s\n' "${body}"
	done < <(list_heredocs HAPROXY "$@")
	if [[ ${first} -eq 1 ]]; then
		printf 'no HAPROXY heredocs found (run_lb in entrypoint.sh)\n' >&2
		return 1
	fi
}

lint_haproxy_c() { # src... - syntax-check the assembled config
	assemble_haproxy "$@" | haproxy -c -f /dev/stdin
}

lint_haproxy_style() { # src... - whitespace rules for the assembled config
	local cfg
	cfg=$(assemble_haproxy "$@")
	if [[ -z ${cfg} ]]; then
		printf 'haproxy style: assembled LB config is empty\n' >&2
		return 1
	fi
	if ! printf '%s\n' "${cfg}" | awk '
		/^\t* +/ { printf "%d: space indentation (tabs only)\n", NR; bad = 1 }
		/[ \t]+$/ { printf "%d: trailing whitespace\n", NR; bad = 1 }
		END { exit bad }
	'; then
		printf 'haproxy style: fix the lines above (run_lb in entrypoint.sh)\n' >&2
		return 1
	fi
}

# Every repo YAML file must be canonical yamlfmt output (kyaml profile).
# yamlfmt -d always exits 0, even on a diff, so compare its stdout to
# the file byte for byte instead.
lint_yamlfmt() { # files...
	local f out rc=0
	for f in "$@"; do
		if ! out=$(yamlfmt -o=kyaml "${f}" 2>&1); then
			printf '%s: not parseable as YAML:\n%s\n' "${f}" "${out}" >&2
			rc=1
			continue
		fi
		if ! cmp -s <(printf '%s\n' "${out}") "${f}"; then
			printf '%s: not canonical yamlfmt output (diff: - file, + yamlfmt):\n' "${f}" >&2
			diff <(printf '%s\n' "${out}") "${f}" | sed 's/^/  /' >&2 || true
			rc=1
		fi
	done
	return "${rc}"
}

if [[ ${#sh_files[@]} -gt 0 ]]; then
	run_check "shfmt -l -s (${#sh_files[@]} sh)" shfmt -l -s -d "${sh_files[@]}"
	run_check "shellcheck -o all -x (${#sh_files[@]} sh)" shellcheck -o all -x "${sh_files[@]}"
	run_check "shellcheck directives (${#sh_files[@]} sh)" lint_shellcheck_directives "${sh_files[@]}"
	run_check "heredoc yaml (${#sh_files[@]} sh)" lint_heredocs_yaml "${sh_files[@]}"
	if [[ ${haproxy_tool} -eq 1 ]]; then
		run_check "haproxy -c (assembled LB config)" lint_haproxy_c "${sh_files[@]}"
		run_check "haproxy style (assembled LB config)" lint_haproxy_style "${sh_files[@]}"
	fi
fi
if [[ ${#md_files[@]} -gt 0 ]]; then
	run_check "prettier (${#md_files[@]} md)" "${prettier_cmd[@]}" --check --end-of-line lf "${md_files[@]}"
fi
if [[ ${#yaml_files[@]} -gt 0 ]]; then
	run_check "yamlfmt (${#yaml_files[@]} yml/yaml)" lint_yamlfmt "${yaml_files[@]}"
fi
if [[ ${#docker_files[@]} -gt 0 ]]; then
	for f in "${docker_files[@]}"; do
		run_check "dockerfmt -s -n (${f})" dockerfmt -s -n --check "${f}"
	done
fi
wait_checks

if [[ ${status} -ne 0 ]]; then
	printf '\n[lint] FAILED - see the tool output above for the offending files\n' >&2
fi
exit "${status}"
