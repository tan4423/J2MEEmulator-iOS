#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [ "$(uname -m)" != x86_64 ]; then echo "JarBox PC bundle requires x86_64 Linux/WSL."; exit 2; fi
if ! command -v python3 >/dev/null || ! python3 -c 'import tkinter' 2>/dev/null || ldd ./jarbox-lab | grep -q 'not found'; then
  echo "JarBox needs SDL2, Cairo and Python Tk. Install dependencies? [y/N]"
  read -r answer
  case "$answer" in y|Y|yes|YES) sudo apt-get update && sudo apt-get install -y libsdl2-2.0-0 libcairo2 python3 python3-tk fonts-dejavu-core ca-certificates;; *) exit 2;; esac
fi
sha256sum -c build-sha256.txt
chmod +x jarbox-lab
exec python3 gui.py
