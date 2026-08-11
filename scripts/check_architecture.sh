#!/bin/bash

set -euo pipefail

required_files=(
  "VVTerm/App/AppPlatformComposition+iOS.swift"
  "VVTerm/App/AppPlatformComposition+macOS.swift"
  "VVTerm/Core/SSH/SSHSession+Authentication.swift"
  "VVTerm/Core/SSH/SSHSession+Execution.swift"
  "VVTerm/Core/SSH/SSHSession+SFTP.swift"
  "VVTerm/Core/SSH/SSHSession+Shell.swift"
  "VVTerm/Core/SSH/SSHSession+Upload.swift"
  "VVTerm/Core/SSH/SSHClient+Environment.swift"
  "VVTerm/Core/SSH/SSHClient+Execution.swift"
  "VVTerm/Core/SSH/SSHClient+Mosh.swift"
  "VVTerm/Core/SSH/SSHClient+SFTP.swift"
  "VVTerm/Core/SSH/SSHClient+Shell.swift"
  "VVTerm/Core/SSH/SSHClient+Upload.swift"
)

for path in "${required_files[@]}"; do
  if [[ ! -f "$path" ]]; then
    echo "Missing architecture boundary: $path" >&2
    exit 1
  fi
done

if rg -n "ServerManager\.shared" VVTerm; then
  echo "Production code must receive ServerManager from composition." >&2
  exit 1
fi

if rg -n "RemoteFile(BrowserStore|Entry|TransferCoordinator|PreviewCoordinator|TemporaryStorage|DropPolicy)" VVTerm/Core/SSH; then
  echo "Core SSH must not depend on Remote Files feature models." >&2
  exit 1
fi

if rg -n "commandRevision|toolbarRevision|@Published[^\n]*[Rr]evision" VVTerm/App; then
  echo "macOS command presentation must use typed snapshots, not revision counters." >&2
  exit 1
fi

echo "Architecture convergence checks passed"
