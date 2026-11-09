#!/usr/bin/env bash
# REQ-8. The README describes every part of the setup.
. "$(dirname "$0")/lib/harness.sh"

R=$(cat "$REPO_DIR/README.md")

for h in "## Install" "## What the installer does to your computer" "## Reverting" \
         "## Layout" "## Wired hooks" "## Skills" "## Status line" \
         "## Tools this setup draws on" "## Licence"; do
  assert_contains "$R" "$h"
done

# REQ-8.7. The image is above the first heading.
first_image_line=$(grep -n 'assets/warden.png' "$REPO_DIR/README.md" | head -1 | cut -d: -f1)
first_heading_line=$(grep -n '^# ' "$REPO_DIR/README.md" | head -1 | cut -d: -f1)
if [ -n "$first_image_line" ] && [ "$first_image_line" -lt "$first_heading_line" ]; then
  pass "the image sits above the first heading"
else
  fail "the image is not above the first heading"
fi
if grep -q 'alt="A knight' "$REPO_DIR/README.md"; then
  pass "the image has alt text"
else
  fail "the image has no alt text"
fi

# REQ-8.4. All ten tools are listed.
for t in obra/superpowers github/spec-kit danyuchn/asd-ste100-skill \
         cathrynlavery/diagram-design Graphify-Labs/graphify stablyai/orca \
         manaflow-ai/cmux stigsb/claude-context-monitor firecrawl/pdf-inspector \
         anthropics/claude-plugins-community; do
  assert_contains "$R" "$t"
done

# REQ-8.5
assert_contains "$R" "Windows is not supported"

# REQ-8.8
assert_contains "$R" "--from-archive"
assert_contains "$R" ".warden-backups"

# The skill table names every tracked directory under skills/. Untracked folders are local data.
for s in $(git -C "$REPO_DIR" ls-files -- skills | awk -F/ 'NF > 2 {print $2}' | sort -u); do
  assert_contains "$R" "\`$s\`"
done

# Deferred minor 15. Substring assertions are why a README row for a plugin
# the installer never registers, and a missing row for something it does,
# both survived a review. These two checks read the code, not the prose.

# The link count against the surfaces install.sh actually links.
# shellcheck source=../lib/warden-common.sh
. "$REPO_DIR/lib/warden-common.sh"
set -- $WARDEN_SURFACES $WARDEN_DOC_SURFACES
link_count=$#
number_words="zero one two three four five six seven eight nine ten eleven twelve"
# shellcheck disable=SC2086
count_word=$(printf '%s\n' $number_words | sed -n "$((link_count + 1))p")
if grep -qi "$count_word symbolic links" "$REPO_DIR/README.md"; then
  pass "the README says '$count_word symbolic links', and the code links $link_count"
else
  fail "the README does not say '$count_word symbolic links'; the code links $link_count"
fi

# The wired-hook table against the hook commands in settings.json.
hook_names=$(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' \
  "$REPO_DIR/settings.json" | awk '{print $1}' | sed 's|.*/||' | sort -u)
hook_table=$(awk '/^## Wired hooks$/{f=1;next} /^## /{f=0} f' "$REPO_DIR/README.md")
row_count=$(printf '%s\n' "$hook_table" | grep -c '^| `')
name_count=$(printf '%s\n' "$hook_names" | grep -c .)

for hook in $hook_names; do
  case "$hook_table" in
    *"\`$hook"*) pass "the wired-hook table names $hook" ;;
    *) fail "settings.json wires $hook and the wired-hook table does not name it" ;;
  esac
done
if [ "$row_count" = "$name_count" ]; then
  pass "the wired-hook table has one row per wired hook ($row_count)"
else
  fail "the wired-hook table has $row_count rows for $name_count wired hooks"
fi

harness_exit
