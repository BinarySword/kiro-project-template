#!/usr/bin/env bash
#
# scripts/setup-secrets.sh — idempotent .env secret generator for
# kiro-project-template.
#
# Generates 32-character random secrets for keys that admit generation:
#   AUTH_SECRET   — session signing key
#
# Other `.env.example` keys (Supabase URL/anon/service, DATABASE_URL,
# ANTHROPIC_API_KEY, OPENAI_API_KEY) are externally issued.
#
# Usage:
#   ./scripts/setup-secrets.sh                       # default target (.env)
#   ./scripts/setup-secrets.sh --force               # rewrite placeholders
#   ./scripts/setup-secrets.sh --file <path>
#   ./scripts/setup-secrets.sh --auto-discover       # find every .env.example

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DEFAULT_TARGETS=("$REPO_ROOT/.env")

FORCE_PLACEHOLDERS=0
AUTO_DISCOVER=0
EXPLICIT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --force)         FORCE_PLACEHOLDERS=1; shift ;;
    --auto-discover) AUTO_DISCOVER=1; shift ;;
    --file)          EXPLICIT_FILE="${2:-}"; shift 2 ;;
    --file=*)        EXPLICIT_FILE="${1#--file=}"; shift ;;
    -h|--help) head -20 "$0" | sed 's/^#\s\{0,1\}//'; exit 0 ;;
    *) echo "error: unknown flag: $1" >&2; exit 1 ;;
  esac
done

if ! command -v openssl >/dev/null 2>&1; then
  echo "error: openssl not on PATH" >&2; exit 2
fi

TARGETS=()
if [ -n "$EXPLICIT_FILE" ]; then
  TARGETS=("$EXPLICIT_FILE")
elif [ "$AUTO_DISCOVER" = "1" ]; then
  while IFS= read -r example; do
    dir=$(dirname "$example")
    TARGETS+=("$dir/.env")
  done < <(find "$REPO_ROOT" -type f -name ".env.example" \
             -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null)
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi

[ "${#TARGETS[@]}" -eq 0 ] && { echo "error: no targets resolved" >&2; exit 1; }

gen_secret() { openssl rand -base64 32 | tr -d '\n=+/' | head -c 32; }
placeholder_re='(<[^>]+>|build-placeholder|generate-a-|REPLACE_ME|CHANGE_ME)'

secret_needs_value() {
  local file="$1" key="$2" line val
  [ ! -f "$file" ] && return 0
  line=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 || true)
  [ -z "$line" ] && return 0
  val="${line#${key}=}"; val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
  [ -z "$val" ] && return 0
  if [ "$FORCE_PLACEHOLDERS" = "1" ] && printf "%s" "$val" | grep -Eq "$placeholder_re"; then
    return 0
  fi
  return 1
}

write_kv() {
  local file="$1" key="$2" val="$3" note="$4"
  mkdir -p "$(dirname "$file")"
  if [ ! -f "$file" ]; then
    cat > "$file" <<EOF
# kiro-project-template — local environment (gitignored).

EOF
  fi
  if grep -qE "^${key}=" "$file"; then
    local tmp; tmp=$(mktemp)
    awk -v k="$key" -v v="$val" '$0 ~ "^"k"=" { print k"=\""v"\""; next } { print }' "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    printf "%s=\"%s\"  # %s\n" "$key" "$val" "$note" >> "$file"
  fi
}

refuse_if_tracked() {
  local file="$1" rel
  rel=$(realpath --relative-to="$REPO_ROOT" "$file" 2>/dev/null || echo "$file")
  if git -C "$REPO_ROOT" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
    echo "error: $rel is tracked in git; refusing to write secrets" >&2; exit 1
  fi
}

declare -A SHARED_VALUES
SHARED_KEYS=(AUTH_SECRET)
SHARED_NOTES=("session signing key (rotation = re-sign all sessions)")

for f in "${TARGETS[@]}"; do refuse_if_tracked "$f"; done

echo "Resolved ${#TARGETS[@]} target(s):"
for f in "${TARGETS[@]}"; do
  rel=$(realpath --relative-to="$REPO_ROOT" "$f" 2>/dev/null || echo "$f")
  echo "  - $rel"
done
echo

for i in "${!SHARED_KEYS[@]}"; do
  key="${SHARED_KEYS[$i]}"
  any_needs=0
  for f in "${TARGETS[@]}"; do
    if secret_needs_value "$f" "$key"; then any_needs=1; break; fi
  done
  [ "$any_needs" = "1" ] && SHARED_VALUES[$key]=$(gen_secret)
done

for f in "${TARGETS[@]}"; do
  rel=$(realpath --relative-to="$REPO_ROOT" "$f" 2>/dev/null || echo "$f")
  echo "→ $rel"
  for i in "${!SHARED_KEYS[@]}"; do
    key="${SHARED_KEYS[$i]}"
    note="${SHARED_NOTES[$i]}"
    if secret_needs_value "$f" "$key"; then
      val="${SHARED_VALUES[$key]:-}"
      [ -z "$val" ] && val=$(gen_secret)
      write_kv "$f" "$key" "$val" "$note"
      echo "    ✓ $key (generated)"
    else
      echo "    ✓ $key (already set, kept)"
    fi
  done
  chmod 600 "$f"
  echo "    perm: 0600"
done

echo
echo "Done. ${#TARGETS[@]} target(s) updated."
echo
echo "External tokens still to set manually in .env:"
echo "  NEXT_PUBLIC_SUPABASE_URL / NEXT_PUBLIC_SUPABASE_ANON_KEY"
echo "  SUPABASE_SERVICE_ROLE_KEY / DATABASE_URL"
echo "  ANTHROPIC_API_KEY / OPENAI_API_KEY"
