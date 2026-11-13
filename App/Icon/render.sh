#!/bin/sh
# Renders AppIcon.svg into App/Assets.xcassets/AppIcon.appiconset. Needs rsvg-convert
# (apt install librsvg2-bin / brew install librsvg). The PNGs are committed; rerun after editing the SVG.
set -eu
cd "$(dirname "$0")"
out=../Assets.xcassets/AppIcon.appiconset
mkdir -p "$out"
images=
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((size * scale))
    rsvg-convert -w $px -h $px AppIcon.svg -o "$out/icon_$px.png"
    images="$images{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"${scale}x\",\"filename\":\"icon_$px.png\"},"
  done
done
printf '{"images":[%s],"info":{"author":"xcode","version":1}}\n' "${images%,}" > "$out/Contents.json"
