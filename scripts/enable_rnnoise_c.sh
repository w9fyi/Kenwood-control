#!/usr/bin/env bash
set -euo pipefail

# Enables/disables the RNNOISE_C compilation condition in the Xcode project,
# based on whether ThirdParty/rnnoise/src/rnnoise.h exists.
#
# Usage:
#   scripts/enable_rnnoise_c.sh enable
#   scripts/enable_rnnoise_c.sh disable
#
# After enabling, rebuild the app.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PBX="$ROOT_DIR/Kenwood control.xcodeproj/project.pbxproj"
HDR="$ROOT_DIR/ThirdParty/rnnoise/src/rnnoise.h"

mode="${1:-}"
if [[ "$mode" != "enable" && "$mode" != "disable" ]]; then
  echo "Usage: $0 enable|disable"
  exit 2
fi

if [[ "$mode" == "enable" && ! -f "$HDR" ]]; then
  echo "rnnoise.h not found at:"
  echo "  $HDR"
  echo
  echo "Run:"
  echo "  scripts/install_rnnoise_source.sh"
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if [[ "$mode" == "enable" ]]; then
  # Add RNNOISE_C to SWIFT_ACTIVE_COMPILATION_CONDITIONS (Debug/Release).
  # This project uses filesystem-synchronized groups, so it's easiest/most robust
  # to toggle the compile condition globally in the pbxproj.
  perl -0777 -pe '
    sub add_flag_line {
      my ($line) = @_;
      return $line if $line =~ /\bRNNOISE_C\b/;
      $line =~ s/SWIFT_ACTIVE_COMPILATION_CONDITIONS\s*=\s*\"([^\"]*)\";/SWIFT_ACTIVE_COMPILATION_CONDITIONS = \"RNNOISE_C $1\";/;
      # Clean up accidental double spaces.
      $line =~ s/\"\\s+/\"/;
      $line =~ s/\\s+\"/\"/;
      $line =~ s/\\s{2,}/ /g;
      return $line;
    }

    s/(SWIFT_ACTIVE_COMPILATION_CONDITIONS\s*=\s*\"[^\"]*\";)/add_flag_line($1)/eg;
  ' "$PBX" > "$tmp"
else
  # Remove RNNOISE_C from SWIFT_ACTIVE_COMPILATION_CONDITIONS in target configs.
  perl -0777 -pe '
    sub rm_flag {
      my ($s) = @_;
      $s =~ s/\bRNNOISE_C\b//g;
      $s =~ s/SWIFT_ACTIVE_COMPILATION_CONDITIONS\s*=\s*\"\\s*\\$\\(inherited\\)\\s*\";\\n//g;
      $s =~ s/SWIFT_ACTIVE_COMPILATION_CONDITIONS\s*=\s*\"\\s*\";\\n//g;
      $s =~ s/\"\\s+\"/\" \"/g;
      return $s;
    }
    s/(SWIFT_ACTIVE_COMPILATION_CONDITIONS\s*=\s*\"[^\"]*\";)/rm_flag($1)/eg;
  ' "$PBX" > "$tmp"
fi

mv "$tmp" "$PBX"
echo "Updated:"
echo "  $PBX"
echo "Mode:"
echo "  $mode"
