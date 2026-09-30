#!/usr/bin/env bash
# Refetches assets/banks/*.png from each bank's own favicon.
#
#   tool/fetch_bank_logos.sh
#
# Needs curl and ImageMagick. Banks whose favicon service returns nothing get
# no file, and fall back to the coloured chip in the app. Read
# assets/banks/README.md before redistributing what this downloads.
set -euo pipefail
cd "$(dirname "$0")/.."
out=assets/banks
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

while read -r key domain; do
  [ -z "$key" ] && continue
  curl -sSL --max-time 25 "https://favicone.com/$domain?s=256" -o "$tmp/$key.ico" || continue
  # Anything this small is an error page, not an icon.
  [ "$(stat -c%s "$tmp/$key.ico")" -lt 400 ] && { echo "miss $key"; continue; }
  magick "$tmp/$key.ico[0]" -background none -trim +repage -resize 176x176 \
    -gravity center -extent 192x192 "PNG32:$out/$key.png" 2>/dev/null \
    && echo "ok   $key" || echo "fail $key"
done <<'DOMAINS'
hdfc hdfcbank.com
sbi bank.sbi
icici icicibank.com
axis axisbank.com
kotak kotak.com
baroda bankofbaroda.in
idfc idfcfirstbank.com
au aubank.in
rbl rblbank.com
bandhan bandhanbank.com
indianoverseas iob.in
central centralbank.net.in
uco ucobank.com
karnataka karnatakabank.com
dcb dcbbank.com
paytm paytm.com
amazon amazon.in
airtel airtel.in
jupiter jupiter.money
slice sliceit.com
citi citi.com
hsbc hsbc.co.in
standardchartered sc.com
dbs dbs.com
DOMAINS

echo
echo "Check the result before committing — the service hands back a generic"
echo "blank-page glyph when it has no icon, and that is not a logo."
