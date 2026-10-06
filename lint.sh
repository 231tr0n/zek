#!/usr/bin/env bash
#
# lint - format/lint checks for every sh, Dockerfile, markdown, YAML and
# GitHub Actions file in the repo. CI runs this same script
# (.github/workflows/lint.yml). All tools run in their strictest mode:
#
#   format sh:          shfmt -l -s -d -i 0 -bn -ci -sr
#                       (list + simplify + diff; tabs; binary operators at
#                       the start of continuation lines; indented case
#                       arms; space after redirect operators)
#   lint sh:            shellcheck -o all -x   (all optional checks + follow sources)
#   lint sh directives: every '# shellcheck disable=' line must still be
#                       required - the directive is stripped and shellcheck
#                       must then report an issue
#   lint sh heredocs:   every heredoc must have a known delimiter and be
#                       linted as what it is: EOF bodies must round-trip
#                       through sigs.k8s.io/yaml/yamlfmt -o=kyaml unchanged
#                       (k8s manifests, parsed the way the shell expands
#                       them; kyaml profile to match the repo YAML files -
#                       only kubectl reads the heredocs and it accepts flow
#                       style, while kubeadm's config decoder sniffs a
#                       leading { as strict JSON, so kubeadm runs on CLI
#                       flags and never reads a heredoc); HAPROXY bodies go
#                       through the LB config checks below; AWK bodies must
#                       parse as awk programs
#   lint sh lb config:  the HAPROXY heredocs are assembled over stdin with
#                       one synthetic backend server, checked with
#                       haproxy -c -f /dev/stdin, and style-checked for
#                       tab-only indentation and trailing whitespace
#   lint Dockerfile:    dockerfmt -s -n --check (space redirects + trailing
#                       newline); every RUN heredoc body is a shell script,
#                       so it is also checked with shellcheck (sh dialect,
#                       the Dockerfile RUN default) and shfmt
#   lint actions:       actionlint over .github/workflows (also runs the
#                       sh checks over every run: block)
#   format md:          prettier --check --end-of-line lf
#   format yaml:        yamlfmt (kyaml profile, compared byte for byte)
#
# Checks run in parallel; every check reads its payload directly (file
# paths on the command line, or the heredoc bodies piped over stdin) and
# only writes the ordered per-check report buffers to disk (mktemp).
#
# Fix locally with:  shfmt -w -s -i 0 -bn -ci -sr <files>  |
#                    prettier --write <files>  |
#                    dockerfmt -s -n -w Dockerfile  |  yamlfmt -w -o=kyaml <files>  |
#                    dnf install haproxy  |
#                    go install sigs.k8s.io/yaml/yamlfmt@latest  |
#                    go install github.com/rhysd/actionlint/cmd/actionlint@latest
#
# The check functions only ever run through run_check's dynamic dispatch
# (their names are passed as arguments), so SC2329 - the unused-function
# check - is disabled for this file. SC2310 - "function invoked in a
# condition" - is disabled per site instead: run_check calls the checks
# under `if`, which turns errexit off inside, so the heredoc checks
# status-check their marker lists explicitly (a plain assignment would
# swallow an unterminated heredoc into an empty list and pass vacuously).
# shellcheck disable=SC2329
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# No arguments: every file comes from git, so a stray argument (a typo'd
# glob, a forgotten remove) must not be silently ignored.
if [[ $# -ne 0 ]]; then
	printf '[lint] usage: %s (takes no arguments)\n' "${0}" >&2
	exit 1
fi

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
	} > "${buf}" 2>&1 &
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

for tool in shfmt shellcheck dockerfmt yamlfmt actionlint; do
	command -v "${tool}" > /dev/null 2>&1 || {
		printf '[lint] missing tool: %s (install it to run this check)\n' "${tool}" >&2
		exit 1
	}
done

# yamlfmt must be the k8s implementation (sigs.k8s.io/yaml/yamlfmt): it is
# the only build with the -o=kyaml profile every YAML check compares
# against, and another yamlfmt on PATH (e.g. mvdan.cc/yamlfmt) would
# silently format differently from CI. The probe exercises that exact
# profile the way the checks below call it.
if ! yprobe=$(printf 'a: 1\n' | yamlfmt -o=kyaml 2>&1) || [[ ${yprobe} != *'{'* ]]; then
	ybin=$(command -v yamlfmt)
	printf '[lint] yamlfmt is not sigs.k8s.io/yaml/yamlfmt (k8s tool with -o=kyaml):\n' >&2
	printf '[lint]   %s: %s\n' "${ybin}" "${yprobe}" >&2
	printf '[lint]   install: go install sigs.k8s.io/yaml/yamlfmt@latest\n' >&2
	exit 1
fi

# prettier: local binary if present, otherwise the latest version via npx
# (CI relies on this npx fallback, so no global npm install is needed).
if command -v prettier > /dev/null 2>&1; then
	prettier_cmd=(prettier)
elif command -v npx > /dev/null 2>&1; then
	prettier_cmd=(npx --yes prettier)
else
	printf '[lint] missing tool: prettier (install prettier or node/npx)\n' >&2
	exit 1
fi

# The LB config checks need a haproxy binary; its absence fails lint but
# does not short-circuit the other checks.
haproxy_tool=1
if ! command -v haproxy > /dev/null 2>&1; then
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
[[ -n ${sh_list} ]] && mapfile -t sh_files <<< "${sh_list}"
[[ -n ${md_list} ]] && mapfile -t md_files <<< "${md_list}"
[[ -n ${yaml_list} ]] && mapfile -t yaml_files <<< "${yaml_list}"
[[ -n ${docker_list} ]] && mapfile -t docker_files <<< "${docker_list}"

# awk program printing one heredoc body to stdout: -s is the opener line,
# -d the delimiter line, -u=1 for quoted openers (no shell escaping to
# strip; an unquoted heredoc's \$ is a literal dollar for the shell, so
# the YAML parser must see plain $).
body_awk=$(
	cat << 'AWK'
	NR > s && $0 == d { exit }
	NR > s { line = $0; if (u == 0) gsub(/\\\$/, "$", line); print line }
AWK
)

# list_heredocs DELIM SRC... - emit one "src:line:quoted:delimiter" marker
# per closed heredoc. DELIM selects the markers: a delimiter name, or "all"
# for every heredoc. Mirrors the shell: comment lines are never openers
# (bash ignores them), a trailing "# ..." comment after code is stripped
# before matching (so `echo hi # << EOF` is not an opener), a here-string
# (<<<) can never match, and the terminator line must equal the delimiter
# exactly - `<<-` (tab-indented terminators) is not supported and fails
# loudly as an unterminated heredoc, as do `<< -EOF` (spaced dash) and two
# openers on one line. A backslash before the delimiter (`<<\EOF`,
# `<< \EOF`) quotes it like a quoted opener and is accepted. Callers must
# check the status: an unterminated heredoc exits 1 and must not degrade
# into an empty marker stream that the checks below would pass vacuously.
list_heredocs() {
	local delim=$1 src
	shift
	for src in "$@"; do
		awk -v delim="${delim}" -v src="${src}" '
			/^[ \t]*#/ && !inbody { next }
			!inbody {
				line = $0
				if (match(line, /[ \t]#/)) {
					pre = substr(line, 1, RSTART)
					if (pre ~ /<</) {
						line = pre
					} else {
						next
					}
				}
				if (line ~ /<<[ \t]+-/) {
					printf "spaced-dash heredoc not supported: %s:%d\n", src, FNR > "/dev/stderr"
					exit 1
				}
				if (match(line, /<<-?[ \t]*\\?[\047"]?[A-Za-z_][A-Za-z0-9_]*/)) {
					m = substr(line, RSTART, RLENGTH)
					rest = substr(line, RSTART + RLENGTH)
					if (rest ~ /<</) {
						printf "multiple heredocs on one line not supported: %s:%d\n", src, FNR > "/dev/stderr"
						exit 1
					}
					name = m
					sub(/^<<-?[ \t]*\\?[\047"]?/, "", name)
					sub(/[\047"]+$/, "", name)
					q = (m ~ /[\047"]/ || m ~ /\\/)
					curdelim = name
					istarget = (delim == "all" || name == delim)
					inbody = 1
					start = FNR
				}
				next
			}
			{
				if ($0 == curdelim) {
					if (istarget) printf "%s:%d:%d:%s\n", src, start, q, name
					inbody = 0
				}
			}
			END {
				if (inbody) {
					printf "unterminated heredoc: %s:%d\n", src, start > "/dev/stderr"
					exit 1
				}
			}
		' "${src}" || return 1
	done
}

# Every EOF heredoc body must be canonical kyaml yamlfmt output:
# parse it exactly as the shell would present it and require yamlfmt
# -o=kyaml to reproduce it byte for byte (a parse error or any diff fails).
lint_heredocs_yaml() {
	local src start quoted _name body canon markers rc=0
	# shellcheck disable=SC2310
	if ! markers=$(list_heredocs EOF "$@"); then
		return 1
	fi
	while IFS=: read -r src start quoted _name; do
		[[ -n ${src} ]] || continue
		if ! body=$(awk -v s="${start}" -v d=EOF -v u="${quoted}" "${body_awk}" "${src}"); then
			printf '%s:%s: cannot read heredoc body\n' "${src}" "${start}" >&2
			rc=1
			continue
		fi
		if [[ -z ${body} ]]; then
			printf '%s:%s: empty EOF heredoc (no YAML body to lint)\n' "${src}" "${start}" >&2
			rc=1
			continue
		fi
		if ! canon=$(printf '%s\n' "${body}" | yamlfmt -o=kyaml 2>&1); then
			printf '%s:%s: not parseable as YAML for formatting:\n%s\n' \
				"${src}" "${start}" "${canon}" >&2
			rc=1
			continue
		fi
		if [[ ${body} != "${canon}" ]]; then
			printf '%s:%s: heredoc is not canonical yamlfmt kyaml output (diff: - source, + yamlfmt -o=kyaml):\n' \
				"${src}" "${start}" >&2
			diff <(printf '%s\n' "${body}") <(printf '%s\n' "${canon}") | sed 's/^/  /' >&2 || true
			rc=1
		fi
	done <<< "${markers}"
	return "${rc}"
}

# Every heredoc must have a delimiter the checks above (or the checks below)
# understand, so a new heredoc cannot silently escape linting: EOF is the
# kyaml manifest check, HAPROXY the LB config checks, AWK the awk parse
# check in this file. Only *.sh files are scanned here: heredocs in
# workflow run: blocks are covered by actionlint's embedded shell
# checks instead, and a Dockerfile RUN heredoc is linted as shell by
# lint_dockerfile_heredocs (its EOF body is covered here as well).
lint_heredoc_coverage() {
	local src start quoted name markers rc=0
	# shellcheck disable=SC2310
	if ! markers=$(list_heredocs all "$@"); then
		return 1
	fi
	while IFS=: read -r src start quoted name; do
		[[ -n ${src} ]] || continue
		case "${name}" in
			EOF | HAPROXY | AWK) ;;
			*)
				printf '%s:%s: heredoc delimiter %s is not linted (known: EOF=kyaml manifests, HAPROXY=LB config, AWK=awk programs)\n' \
					"${src}" "${start}" "${name}" >&2
				rc=1
				;;
		esac
	done <<< "${markers}"
	return "${rc}"
}

# Every AWK heredoc body must parse as an awk program. The body_awk program
# in this file is what every check above reads heredoc bodies with, so a
# typo in it would otherwise corrupt the marker stream itself.
lint_heredoc_awk() {
	local src start quoted _name body err markers rc=0
	# shellcheck disable=SC2310
	if ! markers=$(list_heredocs AWK "$@"); then
		return 1
	fi
	while IFS=: read -r src start quoted _name; do
		[[ -n ${src} ]] || continue
		if ! body=$(awk -v s="${start}" -v d=AWK -v u="${quoted}" "${body_awk}" "${src}"); then
			printf '%s:%s: cannot read AWK heredoc body\n' "${src}" "${start}" >&2
			rc=1
			continue
		fi
		if ! err=$(awk -f <(printf '%s\n' "${body}") < /dev/null 2>&1 > /dev/null); then
			printf '%s:%s: heredoc body does not parse as an awk program:\n%s\n' \
				"${src}" "${start}" "${err}" >&2
			rc=1
		fi
	done <<< "${markers}"
	return "${rc}"
}

# Every '# shellcheck disable=' directive must be required for one of the
# codes it lists: strip the line and require shellcheck to report at least
# one of those codes (a file-level pass, or a failure in an unrelated code
# only, means the directive is unnecessary). shellcheck reads the file over
# stdin (the shebang in the stream picks the dialect), so nothing hits the
# disk. Only disable= directives are checked here; source= directives
# (e.g. for runtime-generated files) are out of scope.
lint_shellcheck_directives() {
	local file lineno rc=0
	for file in "$@"; do
		while IFS=: read -r lineno _; do
			[[ -n ${lineno} ]] || continue
			# shellcheck disable=SC2310
			if ! required_shellcheck_codes "${file}" "${lineno}"; then
				printf '%s:%s: unnecessary shellcheck disable (none of its codes fire without it)\n' \
					"${file}" "${lineno}" >&2
				rc=1
			fi
		done < <(grep -nE '^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+disable=' "${file}" || true)
	done
	return "${rc}"
}

# required_shellcheck_codes FILE LINENO - true when removing the disable
# directive on LINENO makes shellcheck report one of its listed codes.
required_shellcheck_codes() {
	local file=$1 lineno=$2 line codes pattern output
	line=$(sed -n "${lineno}p" "${file}")
	codes=$(printf '%s\n' "${line}" | sed -nE 's/.*disable=([A-Za-z0-9, ]+).*/\1/p' | tr -d ' ')
	[[ -n ${codes} ]] || return 0
	pattern=$(printf '%s\n' "${codes}" | sed 's/,/|/g')
	if ! output=$(sed "${lineno}d" "${file}" | shellcheck -o all -x -f gcc - 2>&1); then
		printf '%s\n' "${output}" | grep -qE "\[(${pattern})\]"
	else
		return 1
	fi
}

# assemble_haproxy SRC... - print the complete LB config: the HAPROXY
# heredoc bodies in order, with one synthetic backend server line between
# them (run_lb prints a real one per control-plane IP at runtime).
assemble_haproxy() {
	local src start quoted _name body markers first=1
	# shellcheck disable=SC2310
	if ! markers=$(list_heredocs HAPROXY "$@"); then
		return 1
	fi
	while IFS=: read -r src start quoted _name; do
		[[ -n ${src} ]] || continue
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
	done <<< "${markers}"
	if [[ ${first} -eq 1 ]]; then
		printf 'no HAPROXY heredocs found (run_lb in entrypoint.sh)\n' >&2
		return 1
	fi
}

lint_haproxy_c() { # src... - syntax-check the assembled config
	local cfg
	# Same guard as lint_haproxy_style: assemble_haproxy's error is
	# already on stderr, and piping a partial config into haproxy would
	# hide it behind haproxy's own confusing empty-input failure
	# (errexit is off under run_check's `if`).
	# shellcheck disable=SC2310
	if ! cfg=$(assemble_haproxy "$@"); then
		return 1
	fi
	printf '%s\n' "${cfg}" | haproxy -c -f /dev/stdin
}

lint_haproxy_style() { # src... - whitespace rules for the assembled config
	local cfg
	# Honor assemble_haproxy's status: its error is already on stderr,
	# and style-checking a partially assembled config would hide the
	# failure (errexit is off under run_check's `if`).
	# shellcheck disable=SC2310
	if ! cfg=$(assemble_haproxy "$@"); then
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

# Every Dockerfile RUN heredoc body is a shell script that docker executes,
# so it gets the same treatment as a .sh file: shellcheck (sh dialect, the
# Dockerfile RUN default shell) and shfmt. The heredoc must sit at the end
# of a leading RUN instruction - that is the only Dockerfile form that
# executes a heredoc as shell - and must be EOF-terminated like every other
# linted heredoc (the coverage check above allows no other name).
lint_dockerfile_heredocs() { # src...
	local src start quoted name body markers opener rc=0
	# In a variable: the << in a literal =~ RHS parses as a redirect.
	local run_re='^[[:space:]]*RUN[[:space:]]+<<'
	# shellcheck disable=SC2310
	if ! markers=$(list_heredocs all "$@"); then
		return 1
	fi
	while IFS=: read -r src start quoted name; do
		[[ -n ${src} ]] || continue
		opener=$(sed -n "${start}p" "${src}")
		if [[ ! ${opener} =~ ${run_re} ]]; then
			printf '%s:%s: heredoc is not executed by a RUN step (only RUN heredocs are linted as shell)\n' \
				"${src}" "${start}" >&2
			rc=1
			continue
		fi
		if [[ ${name} != EOF ]]; then
			printf '%s:%s: RUN heredoc delimiter %s is not EOF (the only name linted here)\n' \
				"${src}" "${start}" "${name}" >&2
			rc=1
			continue
		fi
		if ! body=$(awk -v s="${start}" -v d="${name}" -v u="${quoted}" "${body_awk}" "${src}"); then
			printf '%s:%s: cannot read heredoc body\n' "${src}" "${start}" >&2
			rc=1
			continue
		fi
		if ! printf '%s\n' "${body}" | shellcheck --shell=sh -o all -x -; then
			rc=1
		fi
		if ! printf '%s\n' "${body}" | shfmt -ln posix -s -d -i 0 -bn -ci -sr - > /dev/null; then
			printf '%s:%s: RUN heredoc body is not canonical shfmt output (fix: shfmt -w -s -i 0 -bn -ci -sr in the body)\n' \
				"${src}" "${start}" >&2
			rc=1
		fi
	done <<< "${markers}"
	return "${rc}"
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
			printf '%s: not canonical yamlfmt output (diff: < yamlfmt, > file):\n' "${f}" >&2
			diff <(printf '%s\n' "${out}") "${f}" | sed 's/^/  /' >&2 || true
			rc=1
		fi
	done
	return "${rc}"
}

if [[ ${#sh_files[@]} -gt 0 ]]; then
	run_check "shfmt -l -s -i 0 -bn -ci -sr (${#sh_files[@]} sh)" \
		shfmt -l -s -d -i 0 -bn -ci -sr "${sh_files[@]}"
	run_check "shellcheck -o all -x (${#sh_files[@]} sh)" shellcheck -o all -x "${sh_files[@]}"
	run_check "shellcheck directives (${#sh_files[@]} sh)" lint_shellcheck_directives "${sh_files[@]}"
	run_check "heredoc yaml (${#sh_files[@]} sh)" lint_heredocs_yaml "${sh_files[@]}"
	run_check "heredoc coverage (${#sh_files[@]} sh)" lint_heredoc_coverage "${sh_files[@]}"
	run_check "heredoc awk (${#sh_files[@]} sh)" lint_heredoc_awk "${sh_files[@]}"
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
	run_check "RUN heredoc shell (${#docker_files[@]} Dockerfile)" lint_dockerfile_heredocs "${docker_files[@]}"
fi
run_check "actionlint" actionlint
wait_checks

if [[ ${status} -ne 0 ]]; then
	printf '\n[lint] FAILED - see the tool output above for the offending files\n' >&2
fi
exit "${status}"
