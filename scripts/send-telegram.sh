#!/usr/bin/env bash
# Send briefing HTML to Telegram. Splits long briefings into multiple messages
# at paragraph (then line) boundaries so HTML tags stay balanced.
# Falls back to plain text per-chunk if HTML parse fails.
# Usage: bash scripts/send-telegram.sh briefing.html
set -euo pipefail

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN not set}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID not set}"

FILE="${1:?briefing file required}"
MAX_LEN="${MAX_LEN:-4000}"   # safety margin under Telegram's 4096 cap

if [ ! -f "$FILE" ] || [ ! -s "$FILE" ]; then
  echo "Briefing file empty or missing: $FILE" >&2
  exit 1
fi

send() {
  local mode="$1"
  local text="$2"
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "parse_mode=${mode}" \
    --data-urlencode "disable_web_page_preview=true" \
    --data-urlencode "text=${text}"
}

send_chunk() {
  local text="$1"
  local response ok
  response=$(send "HTML" "$text")
  ok=$(echo "$response" | jq -r '.ok')
  if [ "$ok" != "true" ]; then
    echo "HTML send failed, retrying as plain text. Response:" >&2
    echo "$response" >&2
    # Strip tags + unescape entities so the fallback shows clean text,
    # not raw <a href="...">…</a> soup, when the HTML is malformed.
    local plain
    plain=$(printf '%s' "$text" | sed -E 's/<[^>]+>//g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g')
    response=$(send "" "$plain")
    ok=$(echo "$response" | jq -r '.ok')
  fi
  if [ "$ok" != "true" ]; then
    echo "Telegram send failed:" >&2
    echo "$response" >&2
    return 1
  fi
}

# Split file into ≤ MAX_LEN chunks. Tries paragraph boundary first (\n\n),
# falls back to line boundary (\n) for over-long paragraphs, hard-truncates
# anything still over 4096 (Telegram's hard cap).
split_into_chunks() {
  python3 - "$1" "$MAX_LEN" <<'PY'
import sys, pathlib

path, max_len = sys.argv[1], int(sys.argv[2])
text = pathlib.Path(path).read_text(encoding="utf-8")

def tlen(s):
    # Telegram counts UTF-16 code units. Non-BMP emoji = 2 units.
    return len(s.encode("utf-16-le")) // 2

def looks_like_header(p):
    # Short paragraph led by an emoji (any non-ASCII first char) with a <b> tag.
    # Heuristic to keep section headers attached to the body that follows.
    if not p or tlen(p) > 120:
        return False
    first = p.split("\n", 1)[0]
    return first and ord(first[0]) > 127 and "<b>" in p

def greedy_pack(units, joiner):
    chunks, group = [], []
    def group_len():
        return sum(tlen(p) for p in group) + tlen(joiner) * max(0, len(group) - 1)
    for u in units:
        if not group:
            group = [u]
            continue
        if group_len() + tlen(joiner) + tlen(u) <= max_len:
            group.append(u)
        else:
            # If the last paragraph in the current chunk is a section header,
            # bump it into the next chunk so the header stays with its body.
            if len(group) > 1 and looks_like_header(group[-1]):
                trailing = group.pop()
                chunks.append(joiner.join(group))
                group = [trailing, u]
            else:
                chunks.append(joiner.join(group))
                group = [u]
    if group:
        chunks.append(joiner.join(group))
    return chunks

# 1. Pack by paragraph (blank-line separated)
chunks = greedy_pack(text.split("\n\n"), "\n\n")

# 2. Any chunk still too long? Re-pack that chunk by line.
expanded = []
for c in chunks:
    if tlen(c) <= max_len:
        expanded.append(c)
    else:
        expanded.extend(greedy_pack(c.split("\n"), "\n"))

# 3. Final safety: hard-truncate anything over Telegram's 4096 limit.
for c in expanded:
    if tlen(c) > 4096:
        # Approximate truncation by code point — close enough for safety.
        c = c[:4080] + "…"
    sys.stdout.write(c)
    sys.stdout.write("\0")
PY
}

TEXT=$(cat "$FILE")

# Fast path: single message
if [ ${#TEXT} -le $MAX_LEN ]; then
  send_chunk "$TEXT"
  echo "Telegram send OK (1 message)"
  exit 0
fi

CHUNKS=()
while IFS= read -r -d '' chunk; do
  CHUNKS+=("$chunk")
done < <(split_into_chunks "$FILE")

COUNT=${#CHUNKS[@]}
echo "Briefing length ${#TEXT} > $MAX_LEN — splitting into $COUNT messages"

for i in "${!CHUNKS[@]}"; do
  send_chunk "${CHUNKS[$i]}"
  if [ $((i+1)) -lt $COUNT ]; then
    sleep 0.5
  fi
done

echo "Telegram send OK ($COUNT messages)"
