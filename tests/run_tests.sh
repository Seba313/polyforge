#!/usr/bin/env bash
# Runs all Polyforge tests. Editor tests run in temporary copies of the
# project, so your scenes and editor settings are never touched.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-godot}"
MESHBUILDER="${MESHBUILDER:-$HERE/../meshbuilder}"
status=0
# Every Godot run gets a throw-away config/data/cache home: tests (and addons
# loaded by them, e.g. MeshBuilder) can never write your editor settings.
ISO="$(mktemp -d)"
export XDG_CONFIG_HOME="$ISO/config" XDG_DATA_HOME="$ISO/data" XDG_CACHE_HOME="$ISO/cache"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
# English editor UI, so the tests see Polyforge's English texts on any system.
mkdir -p "$XDG_CONFIG_HOME/godot"
printf '[gd_resource type="EditorSettings" format=3]\n\n[resource]\ninterface/editor/editor_language = "en"\n' > "$XDG_CONFIG_HOME/godot/editor_settings-4.7.tres"
trap 'rm -rf "$ISO"' EXIT
filter() { grep -E "^(==|  ok|  FAIL|  viewport|  \(|RESULT)|SCRIPT ERROR|Parse Error|hides a global"; }

# Runs a test command; fails unless it printed "RESULT: PASS" and no script error.
run_test() {
  local out
  out="$("$@" 2>&1)"
  echo "$out" | filter
  if ! echo "$out" | grep -q "^RESULT: PASS" || echo "$out" | grep -qE "SCRIPT ERROR|Parse Error"; then
    status=1
  fi
}

echo "### core (headless)"
run_test timeout 120 "$GODOT" --headless --path "$HERE" -s tests/unit/test_core.gd
echo "### mesh operations (headless)"
run_test timeout 120 "$GODOT" --headless --path "$HERE" -s tests/unit/test_ops.gd
run_test timeout 120 "$GODOT" --headless --path "$HERE" -s tests/unit/test_ops2.gd
run_test timeout 120 "$GODOT" --headless --path "$HERE" -s tests/unit/test_stage4.gd
run_test timeout 120 "$GODOT" --headless --path "$HERE" -s tests/unit/test_uv.gd

echo "### overlay rendering (real GPU, needs a display)"
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  run_test timeout 60 "$GODOT" --path "$HERE" --resolution 64x64 -s tests/gpu/test_overlay.gd
else
  echo "  (skipped: no display)"
fi

prepare_copy() {   # $1 = target dir
  cp -r "$HERE/." "$1/"
  rm -rf "$1/.godot"
  "$GODOT" --headless --editor --quit-after 300 --path "$1" >/dev/null 2>&1   # first import
  "$GODOT" --headless --path "$1" -s tools/make_test_scene.gd >/dev/null 2>&1
}

echo "### editor integration (temp copy)"
TMP="$(mktemp -d)"
prepare_copy "$TMP"
mkdir -p "$TMP/addons/pf_editor_it"
cp "$HERE/tests/editor_it/"*.gd "$HERE/tests/editor_it/plugin.cfg" "$TMP/addons/pf_editor_it/"
sed -i 's|enabled=PackedStringArray("res://addons/polyforge/plugin.cfg")|enabled=PackedStringArray("res://addons/polyforge/plugin.cfg", "res://addons/pf_editor_it/plugin.cfg")|' "$TMP/project.godot"
run_test timeout 300 "$GODOT" --headless --editor --path "$TMP"
rm -rf "$TMP"

echo "### coexistence with MeshBuilder (temp copy, both plugins enabled)"
if [ -d "$MESHBUILDER" ]; then
  TMP="$(mktemp -d)"
  cp -r "$HERE/." "$TMP/"
  rm -rf "$TMP/.godot"
  cp -r "$MESHBUILDER" "$TMP/addons/meshbuilder"
  sed -i 's|enabled=PackedStringArray("res://addons/polyforge/plugin.cfg")|enabled=PackedStringArray("res://addons/polyforge/plugin.cfg", "res://addons/meshbuilder/plugin.cfg")|' "$TMP/project.godot"
  OUT="$(timeout 200 "$GODOT" --headless --editor --quit-after 400 --path "$TMP" 2>&1)"
  BAD="$(echo "$OUT" | grep -iE "polyforge.*(error|hides)|hides a global script class|Parse Error.*polyforge" || true)"
  if [ -z "$BAD" ]; then
    echo "  ok   Polyforge loads next to MeshBuilder without errors"
  else
    echo "  FAIL errors with MeshBuilder present:"; echo "$BAD" | head -10; status=1
  fi
  rm -rf "$TMP"
else
  echo "  (skipped: MeshBuilder not found at $MESHBUILDER)"
fi
exit $status
