#!/bin/bash
# Install the optional local Inkling model. Does not start or restart any app.
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo 'Usage: bash Scripts/Install-Inkling.sh'
  echo 'Installs Inkling 2 Mini IQ4_NL, its vision encoder, and llama.cpp for Apple Silicon.'
  echo 'Downloads about 18.3 GB. ThoughtStream starts the runtime when a local chat needs it.'
  exit 0
fi
[[ $# == 0 ]] || { echo 'Unexpected argument. Use --help.' >&2; exit 2; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo 'This installer requires an Apple Silicon Mac.' >&2; exit 1;
}

inkling_root="$HOME/Library/Application Support/ThoughtStream/Inkling"
mkdir -p "$inkling_root"

checksum() { shasum -a 256 "$1" | awk '{print $1}'; }
download_checked() {
  local url="$1" filename="$2" expected="$3"
  local destination="$inkling_root/$filename"
  if [[ -f "$destination" ]]; then
    [[ "$(checksum "$destination")" == "$expected" ]] || {
      echo "Checksum mismatch: $destination. Existing file preserved." >&2; exit 1;
    }
    echo "Verified $filename"
    return
  fi
  curl --fail --location --retry 4 --continue-at - "$url" --output "$destination.part"
  [[ "$(checksum "$destination.part")" == "$expected" ]] || {
    echo "Checksum mismatch: $destination.part. Download was not installed." >&2; exit 1;
  }
  mv "$destination.part" "$destination"
  echo "Verified $filename"
}

model_url='https://huggingface.co/ggml-org/Inkling-2-Mini-GGUF/resolve/e8a2cecf0e78914f07cc27b9be711a9b2c7561d9'
download_checked "$model_url/Inkling-2-Mini-IQ4_NL.gguf" Inkling-2-Mini-IQ4_NL.gguf \
  cbdf3fa9dc50a4124977980f37da4f1fa764b0cfe800d275cd43d26ce2a81af4
download_checked "$model_url/mmproj-Inkling-2-Mini-BF16.gguf" mmproj-Inkling-2-Mini-BF16.gguf \
  e914997fe07fb2066bfdce855ec7275c15bc2b624e5423149f1027839593d9cb
download_checked 'https://github.com/ggml-org/llama.cpp/releases/download/b12608/llama-b12608-bin-macos-arm64.tar.gz' \
  llama-b12608-bin-macos-arm64.tar.gz 8c1909d59cf2bbe9c973df786fcf7505c13bcb0d3eb33e8d957bd0f78f805090
tar -xzf "$inkling_root/llama-b12608-bin-macos-arm64.tar.gz" -C "$inkling_root"
echo 'Installed Inkling 2 Mini. In ThoughtStream choose Local Model, then Refresh Models.'
