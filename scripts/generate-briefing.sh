#!/usr/bin/env bash
# Call Google Gemini API to generate Telegram-HTML briefing from data.json
# Usage: bash scripts/generate-briefing.sh data.json > briefing.html
set -euo pipefail

: "${GEMINI_API_KEY:?GEMINI_API_KEY not set}"
DATA_FILE="${1:?data file required}"
MODEL="${GEMINI_MODEL:-gemini-3.5-flash}"

if [ ! -f "$DATA_FILE" ]; then
  echo "Data file not found: $DATA_FILE" >&2
  exit 1
fi

PROMPT_FILE="${PROMPT_FILE:-$(dirname "$0")/../prompts/briefing.md}"
SYSTEM_PROMPT=$(cat "$PROMPT_FILE")
DATA_JSON=$(cat "$DATA_FILE")

USER_MESSAGE=$(jq -n --arg data "$DATA_JSON" '
  "ข้อมูลวันนี้ (JSON):\n\n```json\n" + $data + "\n```\n\nสรุปเป็น briefing HTML ตาม spec ด้านบน — ตอบ output อย่างเดียว ห้ามมี preamble"
')

# Gemini request shape: system_instruction + contents + generationConfig.
# thinkingBudget:0 disables 2.5-flash "thinking" tokens, which otherwise count
# against maxOutputTokens and would starve the visible HTML output.
REQUEST_BODY=$(jq -n \
  --arg system "$SYSTEM_PROMPT" \
  --argjson user_msg "$USER_MESSAGE" \
  '{
    system_instruction: { parts: [ { text: $system } ] },
    contents: [ { role: "user", parts: [ { text: $user_msg } ] } ],
    generationConfig: { maxOutputTokens: 8192, thinkingConfig: { thinkingBudget: 0 } }
  }')

RESPONSE=$(curl -sS "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent" \
  -H "x-goog-api-key: ${GEMINI_API_KEY}" \
  -H "content-type: application/json" \
  -d "$REQUEST_BODY")

# Extract briefing text (join all text parts, defensive against null candidates)
BRIEFING=$(echo "$RESPONSE" | jq -r '([.candidates[0]?.content?.parts[]?.text] | join("")) // empty')

if [ -z "$BRIEFING" ]; then
  echo "Gemini API returned no content. Full response:" >&2
  echo "$RESPONSE" >&2
  exit 1
fi

# Fail loud if the model ran out of output budget: a MAX_TOKENS cutoff leaves the
# HTML truncated mid-tag, which Telegram then rejects and dumps as raw tags.
# Exiting here triggers the workflow's failure path (artifact upload + alert).
STOP_REASON=$(echo "$RESPONSE" | jq -r '.candidates[0].finishReason // empty')
if [ "$STOP_REASON" = "MAX_TOKENS" ]; then
  echo "Output truncated (finishReason=MAX_TOKENS) — raise maxOutputTokens. Usage:" >&2
  echo "$RESPONSE" | jq -c '.usageMetadata' >&2
  exit 1
fi

# Strip leading/trailing markdown code fences if the model wrapped it
BRIEFING=$(echo "$BRIEFING" | sed -e '1{/^```html$/d}' -e '1{/^```$/d}' -e '${/^```$/d}')

echo "$BRIEFING"
