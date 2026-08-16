#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_directory=${script_directory:h}
javascript_directory="$project_directory/SafariExtension/JavaScript"
extension_output="$project_directory/SafariExtension/Generated"
player_output="$project_directory/Sources/PabloApp/Resources/RRWebPlayer"

mkdir -p "$extension_output" "$player_output"
pnpm --dir "$javascript_directory" exec esbuild \
    "$javascript_directory/recorder-entry.js" \
    --bundle \
    --format=iife \
    --platform=browser \
    --target=safari17 \
    --legal-comments=linked \
    --outfile="$extension_output/rrweb-recorder.js"
pnpm --dir "$javascript_directory" exec esbuild \
    "$javascript_directory/player-entry.js" \
    --bundle \
    --format=iife \
    --platform=browser \
    --target=safari17 \
    --legal-comments=linked \
    --outfile="$player_output/player.js"

for legal_notice in "$extension_output"/*.LEGAL.txt(N) "$player_output"/*.LEGAL.txt(N); do
    ruby -pi -e 'gsub(/[ \t]+$/, "")' "$legal_notice"
done

generated_css="$player_output/player.css"
if [[ ! -f $generated_css ]]; then
    echo "rrweb-player CSS was not generated." >&2
    exit 1
fi
