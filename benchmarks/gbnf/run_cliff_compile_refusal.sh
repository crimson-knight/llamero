#!/bin/sh
# Proves that FORCING :grammar on a past-budget type is a compile-time refusal.
# Expected: crystal build fails with the GBNF budget error naming CliffBreaker.
set -u
cd "$(dirname "$0")"
TMP=$(mktemp -d)
cat > "$TMP/forced_grammar_overbudget.cr" <<'EOF'
require "llamero"
require "../src/schemas"
# Forcing :grammar requires the grammar to exist at compile time:
puts CliffBreaker.to_gbnf
EOF
# Place it inside src so relative requires resolve
cp "$TMP/forced_grammar_overbudget.cr" src/_forced_overbudget_tmp.cr
sed -i '' 's|require "../src/schemas"|require "./schemas"|' src/_forced_overbudget_tmp.cr
/opt/homebrew/bin/crystal build src/_forced_overbudget_tmp.cr --no-codegen 2>&1
STATUS=$?
rm -f src/_forced_overbudget_tmp.cr
rm -rf "$TMP"
echo "compile exit status: $STATUS (non-zero = refused at compile time, as designed)"
