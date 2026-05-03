#!/usr/bin/env sh
set -eu

log() {
  printf '%s\n' "symphony workspace bootstrap: $*" >&2
}

die() {
  log "$*"
  exit 1
}

is_valid_uuid() {
  printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

workspace_has_git_repo() {
  git rev-parse --show-toplevel >/dev/null 2>&1
}

workspace_has_non_bootstrap_files() {
  find . -mindepth 1 \
    ! -path './.git' ! -path './.git/*' \
    ! -path './.codex' ! -path './.codex/*' \
    ! -path './.agents' ! -path './.agents/*' \
    -print -quit | grep -q .
}

repo_remote_matches() {
  repo_path="$1"
  expected_clone_url="$2"
  expected_full_name="$3"

  [ -d "$repo_path/.git" ] || return 1

  actual_url="$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)"
  [ -n "$actual_url" ] || return 1

  if [ -n "$expected_clone_url" ] && [ "$actual_url" = "$expected_clone_url" ]; then
    return 0
  fi

  if [ -n "$expected_full_name" ]; then
    case "$actual_url" in
      *"$expected_full_name"* | *"${expected_full_name}.git"*) return 0 ;;
    esac
  fi

  return 1
}

select_local_source_repo() {
  repo_full_name="$1"
  repo_clone_url="$2"
  repo_name="${repo_full_name##*/}"

  if [ -n "$repo_name" ] && repo_remote_matches "/root/code/$repo_name" "$repo_clone_url" "$repo_full_name"; then
    printf '%s\n' "/root/code/$repo_name"
    return 0
  fi

  for repo_path in /root/code/*; do
    if repo_remote_matches "$repo_path" "$repo_clone_url" "$repo_full_name"; then
      printf '%s\n' "$repo_path"
      return 0
    fi
  done

  return 1
}

remote_branch_exists() {
  branch="$1"
  git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1
}

fetch_origin_heads() {
  git fetch --prune origin '+refs/heads/*:refs/remotes/origin/*'
}

local_branch_ref_exists() {
  branch="$1"
  git show-ref --verify --quiet "refs/remotes/origin/$branch" ||
    git show-ref --verify --quiet "refs/heads/$branch"
}

branch_exists() {
  branch="$1"
  local_branch_ref_exists "$branch" || remote_branch_exists "$branch"
}

normalize_workspace_branch() {
  branch="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$branch" in
    "" | main | master) printf '%s\n' "staging" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

checkout_branch() {
  preferred_branch="$1"
  default_branch="$2"

  target_branch=""
  preferred_branch="$(normalize_workspace_branch "$preferred_branch")"
  default_branch="$(normalize_workspace_branch "$default_branch")"

  if [ -n "$preferred_branch" ] && branch_exists "$preferred_branch"; then
    target_branch="$preferred_branch"
  elif [ "$default_branch" != "$preferred_branch" ] && branch_exists "$default_branch"; then
    target_branch="$default_branch"
  fi

  [ -n "$target_branch" ] || die "no checkout branch found on origin; expected staging"

  if git show-ref --verify --quiet "refs/remotes/origin/$target_branch"; then
    git checkout -B "$target_branch" "origin/$target_branch"
  elif git show-ref --verify --quiet "refs/heads/$target_branch"; then
    git checkout "$target_branch"
  else
    git fetch --depth 1 origin "$target_branch"
    git checkout -B "$target_branch" "origin/$target_branch"
  fi

  log "checked out $target_branch"
}

[ -n "${SYMPHONY_ISSUE_ID:-}" ] || die "SYMPHONY_ISSUE_ID is not set"
is_valid_uuid "$SYMPHONY_ISSUE_ID" || die "SYMPHONY_ISSUE_ID is not a UUID: $SYMPHONY_ISSUE_ID"
[ -n "${PITCHAI_PM_DATABASE_URL:-}" ] || die "PITCHAI_PM_DATABASE_URL is not set"

if [ -n "${SYMPHONY_WORKSPACE:-}" ]; then
  mkdir -p "$SYMPHONY_WORKSPACE"
  cd "$SYMPHONY_WORKSPACE"
fi

if workspace_has_git_repo; then
  log "workspace already has a git repository"
  exit 0
fi

if workspace_has_non_bootstrap_files; then
  die "workspace is non-empty but is not a git repository"
fi

repo_row="$(
  psql "$PITCHAI_PM_DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -F '	' -c "
    select
      coalesce(nullif(gr.repo_full_name, ''), '') as repo_full_name,
      coalesce(nullif(gr.repo_clone_url, ''), '') as repo_clone_url,
      coalesce(nullif(gr.default_branch, ''), '') as default_branch
    from public.tasks t
    left join pitchai_dispatch.project_git_repos gr on gr.project_id = t.project_id
    where t.id = '${SYMPHONY_ISSUE_ID}'::uuid
    order by gr.updated_at desc nulls last
    limit 1
  "
)"

[ -n "$repo_row" ] || die "no PM task or linked project repo found for $SYMPHONY_ISSUE_ID"

repo_full_name="$(printf '%s' "$repo_row" | awk -F '	' '{print $1}')"
repo_clone_url="$(printf '%s' "$repo_row" | awk -F '	' '{print $2}')"
default_branch="$(printf '%s' "$repo_row" | awk -F '	' '{print $3}')"

[ -n "$repo_full_name" ] || die "task project has no linked repo_full_name"
if [ -z "$repo_clone_url" ]; then
  repo_clone_url="https://github.com/${repo_full_name}.git"
fi

rm -rf ./.git ./.codex ./.agents

source_repo="$(select_local_source_repo "$repo_full_name" "$repo_clone_url" || true)"
if [ -n "$source_repo" ]; then
  log "cloning local source $source_repo for $repo_full_name"
  git clone --no-local "$source_repo" .
  git remote set-url origin "$repo_clone_url" || true
  fetch_origin_heads
else
  log "cloning remote source $repo_clone_url"
  git clone "$repo_clone_url" .
fi

checkout_branch "${SYMPHONY_WORKSPACE_BRANCH:-staging}" "$default_branch"
