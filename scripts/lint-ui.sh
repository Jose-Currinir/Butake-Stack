#!/bin/bash
# Counts in native/Sources the interface practices of docs/estandar-ui.md that can be checked
# by text, and fails when a counter goes over its cap in scripts/lint-ui.baseline (name=number).
# --update lowers each cap to its current value; caps never go up.
#
# Exemptions: a line that carries `// lint-ui: <reason>` is a deliberate, reviewed case (a drawing
# on a fixed grid, data written in capitals) and no counter counts it. Exemptions are not silent:
# they are listed below the table with their reason and have their own counter and cap.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCES="$ROOT/native/Sources"
BASELINE="$ROOT/scripts/lint-ui.baseline"
UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

# Lines of the Swift sources that match, without the exempted ones.
swift_lines() { grep -rn --include='*.swift' -E "$1" "$SOURCES" | grep -v '// lint-ui: ' || true; }
count() { grep -c . || true; }

# Fixed point sizes; Shared/Typography.swift defines the scale and is the only place allowed.
fixed_font() {
    swift_lines '\.(ui|system)\(size:' | grep -v '/Shared/Typography.swift:' | count
}
on_tap() { swift_lines 'onTapGesture' | count; }
uppercased() { swift_lines '\.uppercased\(\)' | count; }
# Text("…") with a literal that has letters once interpolations are left out ("—", "\(n)" pass).
text_literal() {
    swift_lines 'Text\("[^"]' | grep -oE 'Text\("[^"]*' | sed -e 's/^Text("//' -e 's/\\(.*//' | grep -E '[[:alpha:]]' | count
}
# SF Symbols written as a literal instead of taken from Shared/Symbols.swift.
symbol_literal() {
    swift_lines '(systemName|systemImage): *"' | grep -v '/Shared/Symbols.swift:' | count
}
# A concept of Symbols written by hand anywhere a symbol is chosen (also inside ternaries).
symbol_concept() {
    local values
    values="$(grep -oE 'static let [A-Za-z]+ = "[^"]+"' "$SOURCES/ButakeStack/Shared/Symbols.swift" | sed -E 's/.*= "([^"]+)"/\1/' | sort -u | sed 's/\./\\./g' | paste -sd '|' -)"
    swift_lines '(systemName|systemImage|symbol):' | grep -v '/Shared/Symbols.swift:' | grep -oE "\"($values)\"" | count
}
# Symbols tinted with the accent by hand: icons of a row go on their tile (IconTile, TileColor).
tinted_icon() {
    swift_lines 'Image\(systemName:[^)]*\).*foregroundStyle\(Brand\.accent\)' | count
}
# Apps and package or container managers that Stack replaces or avoids are never named.
third_party() {
    grep -rniwE --include='*.swift' --include='*.strings' 'herd|dbngin|tableplus|termius|tinkerwell|dbeaver|valet|mamp|laragon|homebrew|docker' "$SOURCES" | count
}
# The product is called «Stack» (P-24): the old name never reaches a visible text, the bundle or
# the installer. Only the name of the old data folder is still written, where it is resolved
# (`Folder.oldDataName`, like `OLD_DATA_FOLDER` in the engine).
old_product_name() {
    { grep -rn --include='*.swift' --include='*.strings' --include='*.stringsdict' 'Butake Stack' "$SOURCES" || true
      grep -n 'Butake Stack' "$ROOT/scripts/build-native.sh" "$ROOT/scripts/install-native.sh" "$ROOT/scripts/package-dmg.sh" "$ROOT/scripts/run-native.sh" "$ROOT/scripts/dmg-background.swift" || true
    } | grep -v 'static let oldDataName = "Butake Stack"' | count
}
# Containers that wave D replaced with Form(.grouped): they no longer exist.
deprecated_containers() {
    swift_lines '\b(CardBlock|CardSection|RowGroup|GroupedRow|SettingRow|HeaderCard|PageHeader)\b' | count
}
# A view that asks for its ideal height: outside a ScrollView, Form or List it makes the window's
# minimum taller than the window and the columns start under the title bar (P-15). Text wraps by
# itself; a row that needs the width takes it with frame(maxWidth:).
fixed_size_vertical() { swift_lines 'fixedSize\(horizontal: *false, *vertical: *true\)' | count; }
# A plain button is an action without the look of one; rows that open something are List rows
# (List(selection:), NavigationLink) and the few custom ones use a style of Shared/.
plain_button() { swift_lines 'buttonStyle\(\.plain\)|buttonStyle\(PlainButtonStyle\(\)\)' | count; }
# System text styles (.font(.caption), .callout…) do not follow Stack's text size: the scale of
# Shared/Typography.swift (.uiCaption, .uiSubheadline…) and ButakeDesign's does. The cap is per file.
SYSTEM_STYLE='\.font\(\.(largeTitle|title[23]?|headline|subheadline|body|callout|footnote|caption2?)\b'
system_font_style() { swift_lines "$SYSTEM_STYLE" | count; }
# "file count" lines of the counters whose cap is per file (a fix in one file cannot pay for a new case in another).
files_of() {
    case "$1" in
        system-font-style) swift_lines "$SYSTEM_STYLE" ;;
        *) return 0 ;;
    esac | cut -d: -f1 | sed "s|^$SOURCES/ButakeStack/||" | sort | uniq -c | awk '{print $2, $1}'
}
# Sheets whose fixed (or minimum) height is taller than the window's minimum, 600 pt (ButakeStackApp):
# they do not fit it and lose their buttons. A sheet takes minHeight and scrolls.
MIN_WINDOW_HEIGHT=600
SHEET_HEIGHT='\.frame\([^)]*\b(minHeight|height): *[0-9]+'
sheet_taller_than_window() {
    swift_lines "$SHEET_HEIGHT" | grep -oE '\b(minHeight|height): *[0-9]+' | grep -oE '[0-9]+$' | awk -v max="$MIN_WINDOW_HEIGHT" '$1 > max' | count
}
# Swift files over 500 lines: one file per responsibility (rule 28, done definition §11).
file_too_long() {
    find "$SOURCES" -name '*.swift' -print0 | xargs -0 wc -l | grep -v ' total$' | awk '$1 > 500' | count
}
# Structural checks (a dialog and its buttons, a toolbar item and its content) need the block,
# not the line: scripts/lint-ui-blocks.py prints one line per finding.
blocks() { /usr/bin/python3 -I "$ROOT/scripts/lint-ui-blocks.py" "$SOURCES" "$1"; }
dialog_without_cancel() { blocks dialogs | count; }
toolbar_item_without_label() { blocks toolbar | count; }
icon_only_without_help() { blocks icononly | count; }
exemptions() { grep -rn --include='*.swift' '// lint-ui: ' "$SOURCES" | count; }
# Localizable.strings ordered by area (scripts/order-strings.py): keys out of their place.
strings_order() { /usr/bin/python3 -I "$ROOT/scripts/order-strings.py" --count; }

NAMES="fixed-font system-font-style on-tap-gesture uppercased text-literal symbol-literal symbol-concept tinted-icon third-party old-product-name deprecated-containers fixed-size-vertical dialog-without-cancel plain-action-button toolbar-item-without-label icon-only-without-help sheet-taller-than-window file-too-long strings-order exemptions"
current() {
    case "$1" in
        fixed-font) fixed_font ;;
        system-font-style) system_font_style ;;
        on-tap-gesture) on_tap ;;
        uppercased) uppercased ;;
        text-literal) text_literal ;;
        symbol-literal) symbol_literal ;;
        symbol-concept) symbol_concept ;;
        tinted-icon) tinted_icon ;;
        third-party) third_party ;;
        old-product-name) old_product_name ;;
        deprecated-containers) deprecated_containers ;;
        fixed-size-vertical) fixed_size_vertical ;;
        dialog-without-cancel) dialog_without_cancel ;;
        plain-action-button) plain_button ;;
        toolbar-item-without-label) toolbar_item_without_label ;;
        icon-only-without-help) icon_only_without_help ;;
        sheet-taller-than-window) sheet_taller_than_window ;;
        file-too-long) file_too_long ;;
        strings-order) strings_order ;;
        exemptions) exemptions ;;
    esac
}
cap() { [ -f "$BASELINE" ] && grep -E "^$1=" "$BASELINE" | head -1 | cut -d= -f2 || true; }

failed=0
updated=""
printf '%-28s %8s %8s\n' "contador" "actual" "tope"
for name in $NAMES; do
    value="$(current "$name" | tr -d ' ')"
    limit="$(cap "$name")"
    mark=""
    if [ -z "$limit" ]; then
        if [ "$UPDATE" -eq 1 ]; then limit="$value"; else mark="  sin tope"; failed=1; fi
    elif [ "$value" -gt "$limit" ]; then
        mark="  SUPERA EL TOPE"; failed=1
    elif [ "$UPDATE" -eq 1 ] && [ "$value" -lt "$limit" ]; then
        limit="$value"
    fi
    printf '%-28s %8s %8s%s\n' "$name" "$value" "${limit:--}" "$mark"
    updated="$updated$name=${limit:-$value}
"
    # A counter with a cap per file: each file against its own cap (`name:file=number`, 0 when absent).
    while read -r file n; do
        [ -n "$file" ] || continue
        filecap="$(awk -F= -v k="$name:$file" '$1 == k { print $2; exit }' "$BASELINE" 2>/dev/null || true)"
        if [ -z "$filecap" ]; then
            if [ "$UPDATE" -eq 1 ]; then filecap="$n"; else filecap=0; fi
        fi
        if [ "$n" -gt "$filecap" ]; then
            printf '  %-26s %8s %8s  SUPERA EL TOPE DEL ARCHIVO\n' "$file" "$n" "$filecap"; failed=1
        elif [ "$UPDATE" -eq 1 ]; then
            filecap="$n"
        fi
        updated="$updated$name:$file=$filecap
"
    done <<LISTEND
$(files_of "$name")
LISTEND
done

# Every exemption, with its file, line and reason.
if [ "$(exemptions | tr -d ' ')" -gt 0 ]; then
    echo
    echo "Exenciones (// lint-ui: <motivo>):"
    grep -rn --include='*.swift' '// lint-ui: ' "$SOURCES" | sed -E "s|^$SOURCES/ButakeStack/||; s|^([^:]+:[0-9]+):.*// lint-ui: (.*)$|  \1  \2|"
fi
# Findings of the counters over zero, so they can be fixed from the output.
if [ "${LINT_UI_VERBOSE:-0}" = "1" ]; then
    blocks dialogs | sed 's/^/  diálogo sin cancelar: /'
    blocks toolbar | sed 's/^/  barra sin Label: /'
    blocks icononly | sed 's/^/  ícono solo: /'
    swift_lines "$SYSTEM_STYLE" | sed -E "s|^$SOURCES/ButakeStack/||" | cut -c1-150 | sed 's/^/  fuente del sistema: /'
    swift_lines "$SHEET_HEIGHT" | awk -v max="$MIN_WINDOW_HEIGHT" '{ if (match($0, /(minHeight|height): *[0-9]+/)) { v = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", v); if (v + 0 > max) print } }' | sed -E "s|$SOURCES/ButakeStack/||" | cut -c1-150 | sed 's/^/  hoja más alta que la ventana mínima: /'
fi

if [ "$UPDATE" -eq 1 ]; then
    if [ "$failed" -eq 0 ]; then printf '%s' "$updated" > "$BASELINE"; echo "Topes actualizados en scripts/lint-ui.baseline."; fi
fi
if [ "$failed" -ne 0 ]; then
    echo "lint-ui: hay contadores sobre su tope (los topes solo bajan; corrige el código)." >&2
    exit 1
fi
