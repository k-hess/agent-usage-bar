#!/bin/sh
# Regenerates AppIcon.icns. Requires ImageMagick (brew install imagemagick).
# A white gauge ring on the Claude orange squircle; the ring sits at ~70% so the
# icon reads as "usage" rather than "loading".
set -e
cd "$(dirname "$0")"

magick -size 824x824 gradient:'#E8917A-#C4562F' bg.png
magick -size 824x824 xc:black -fill white -draw "roundrectangle 0,0,823,823,185,185" mask.png
magick bg.png mask.png -alpha off -compose CopyOpacity -composite tile.png
magick -size 1024x1024 xc:none tile.png -geometry +100+100 -compose over -composite \
  -draw "fill none stroke-linecap round stroke rgba(255,255,255,0.28) stroke-width 70 arc 282,282 742,742 135,405" \
  -draw "fill none stroke-linecap round stroke white stroke-width 70 arc 282,282 742,742 135,324" \
  icon-1024.png
rm -f bg.png mask.png tile.png

rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  magick icon-1024.png -resize ${s}x${s} AppIcon.iconset/icon_${s}x${s}.png
  magick icon-1024.png -resize $((s * 2))x$((s * 2)) AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
