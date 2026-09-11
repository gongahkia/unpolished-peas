#!/usr/bin/env bash
set -euo pipefail

cli="${PX240C_CLI:-target/debug/px240c}"
if [[ ! -x "${cli}" ]]; then
  echo "release artifact verifier requires executable ${cli}" >&2
  exit 1
fi

artifact_dir=$(mktemp -d)
cleanup() {
  if [[ -n "${artifact_dir}" && -d "${artifact_dir}" ]]; then
    rm -rf "${artifact_dir}"
  fi
}
trap cleanup EXIT

cartridges=(
  cinder-circuit
  ashvault
  raster-rush
  px240c-service
  signal-4k
  pocket-relay
  hardware-gauntlet
  pxcl-tutorial
)

printf 'cartridge\tpxc-bytes\tpxc-sha256\tpxc.png-sha256\thtml-sha256\tzip-sha256\n'
for cartridge in "${cartridges[@]}"; do
  project="cartridges/${cartridge}"
  first="${artifact_dir}/${cartridge}-a"
  second="${artifact_dir}/${cartridge}-b"

  "${cli}" pack "${project}" --output "${first}.pxc" >/dev/null
  "${cli}" pack "${project}" --output "${second}.pxc" >/dev/null
  "${cli}" export png "${project}" --output "${first}.pxc.png" >/dev/null
  "${cli}" export png "${project}" --output "${second}.pxc.png" >/dev/null
  "${cli}" export html "${project}" --output "${first}.html" >/dev/null
  "${cli}" export html "${project}" --output "${second}.html" >/dev/null
  "${cli}" export zip "${project}" --output "${first}.zip" >/dev/null
  "${cli}" export zip "${project}" --output "${second}.zip" >/dev/null

  cmp "${first}.pxc" "${second}.pxc"
  cmp "${first}.pxc.png" "${second}.pxc.png"
  cmp "${first}.html" "${second}.html"
  cmp "${first}.zip" "${second}.zip"
  "${cli}" info "${first}.pxc.png" >/dev/null
  "${cli}" run "${first}.pxc" --headless --frames 5 >/dev/null

  pxc_bytes=$(wc -c < "${first}.pxc" | tr -d ' ')
  pxc_hash=$(shasum -a 256 "${first}.pxc" | awk '{print $1}')
  png_hash=$(shasum -a 256 "${first}.pxc.png" | awk '{print $1}')
  html_hash=$(shasum -a 256 "${first}.html" | awk '{print $1}')
  zip_hash=$(shasum -a 256 "${first}.zip" | awk '{print $1}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${cartridge}" "${pxc_bytes}" "${pxc_hash}" "${png_hash}" "${html_hash}" "${zip_hash}"
done
