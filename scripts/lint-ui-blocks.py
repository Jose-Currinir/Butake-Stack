"""Block checks of scripts/lint-ui.sh that a single line can't answer. Prints one finding per line
(path:line: what) for the check named in argv[2]:

dialogs  A .confirmationDialog or .alert whose actions don't declare their cancel button:
         `Button(L("common.cancel"), role: .cancel)`. An alert with a single button (it only
         informs) passes when that button is the one with `role: .cancel`.
toolbar  A control in a ToolbarItem or ToolbarItemGroup whose label is a bare Text or Image instead
         of a Label (VoiceOver, the toolbar's "Icon and Text" mode and the overflow menu read the
         Label's title).

icononly A `.labelStyle(.iconOnly)` whose control has neither `.help(` nor an accessibility label: a
         button with only an icon has no visible name, so the tooltip is the only text a pointer
         user sees. The control is the modifier chain of the Label and, when the Label sits in a
         closure (Button's label, a Menu's), the chain of the view that owns the closure.

A line with `// lint-ui: <reason>` is an exemption and is not reported (scripts/lint-ui.sh lists it).
"""
import pathlib
import re
import sys


def closing(text, start, open_char, close_char):
    """Index of the bracket that closes the one at `start`, skipping string literals."""
    depth, index, in_string = 0, start, False
    while index < len(text):
        char = text[index]
        if in_string:
            if char == "\\":
                index += 1
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == open_char:
            depth += 1
        elif char == close_char:
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return len(text) - 1


def line_of(text, index):
    return text.count("\n", 0, index) + 1


def exempt(text, index):
    end = text.find("\n", index)
    start = text.rfind("\n", 0, index) + 1
    return "// lint-ui: " in text[start:end if end >= 0 else len(text)]


def dialogs(path, text):
    for match in re.finditer(r"\.(confirmationDialog|alert)\(", text):
        if exempt(text, match.start()):
            continue
        close = closing(text, match.end() - 1, "(", ")")
        after = text[close + 1:].lstrip()
        if not after.startswith("{"):
            yield f"{path}:{line_of(text, match.start())}: .{match.group(1)} sin acciones con cancelar"
            continue
        brace = text.index("{", close)
        actions = text[brace:closing(text, brace, "{", "}") + 1]
        if 'Button(L("common.cancel"), role: .cancel)' in actions:
            continue
        buttons = re.findall(r"\bButton\(", actions)
        if len(buttons) == 1 and re.search(r'Button\(L\("[^"]+"\), role: \.cancel\)', actions):
            continue
        yield f"{path}:{line_of(text, match.start())}: .{match.group(1)} sin Button(L(\"common.cancel\"), role: .cancel)"


LABEL_OF_CONTROL = re.compile(r"label:\s*\{\s*(Text|Image)\(")
CONTROL = re.compile(r"\b(Toggle|Menu|Button)\(")
BARE_CONTENT = re.compile(r"\s*\{\s*(Text|Image)\(")
BARE_ITEM = re.compile(r"^\s*(Text|Image)\(", re.M)


def depth(body, index):
    """Brace depth of `index` inside a toolbar item's body (0: an item of its own)."""
    level = 0
    for char in body[:index]:
        level += char == "{"
        level -= char == "}"
    return level


def toolbar(path, text):
    for match in re.finditer(r"\bToolbarItem(Group)?\(", text):
        close = closing(text, match.end() - 1, "(", ")")
        brace = text.find("{", close)
        if brace < 0:
            continue
        body = text[brace + 1:closing(text, brace, "{", "}")]
        found = [m.start() for m in LABEL_OF_CONTROL.finditer(body)]
        # Toggle(isOn: …) { Text(…) }: the trailing closure is the control's label.
        for control in CONTROL.finditer(body):
            if BARE_CONTENT.match(body, closing(body, control.end() - 1, "(", ")") + 1):
                found.append(control.start())
        # A Text or an Image straight in the item (not the options of a Picker or a Menu).
        found += [m.start() for m in BARE_ITEM.finditer(body) if depth(body, m.start()) == 0]
        for start in sorted(found):
            index = brace + 1 + start
            if not exempt(text, index):
                yield f"{path}:{line_of(text, index)}: control de la barra sin Label"


ICON_ONLY = re.compile(r"\.labelStyle\(\.iconOnly\)")
NAMED = re.compile(r"\.help\(|\.accessibilityLabel\(|\.accessibilityHint\(")


CONTROL_FLOW = re.compile(r"^\s*(\}\s*)?(else|if|case|default|switch|guard)\b")
MODIFIER = re.compile(r"\s*\.[A-Za-z]+")


def enclosing_open(text, index):
    """Index of the bracket that is still open at `index`, or -1."""
    depth = 0
    for i in range(index - 1, -1, -1):
        char = text[i]
        if char in ")}]":
            depth += 1
        elif char in "({[":
            if depth == 0:
                return i
            depth -= 1
    return -1


def chain_end(text, start):
    """End of the control that holds the view at `start`: climbs out of the `if`/`else`/`case`
    branches that hold it, then follows the modifiers (`.name(…)`, `.name { … }`) of the view
    that owns the closure (a Button's label, a Menu's, a Group's)."""
    index = start
    while True:
        opener = enclosing_open(text, index)
        if opener < 0:
            return len(text)
        close = closing(text, opener, text[opener], {"(": ")", "{": "}", "[": "]"}[text[opener]])
        header = text[text.rfind("\n", 0, opener) + 1:opener]
        index = close + 1
        if text[opener] == "{" and CONTROL_FLOW.match(header):
            # A control-flow branch: skip the `else` branches that follow and keep climbing.
            while re.compile(r"\s*else\b").match(text, index):
                brace = text.find("{", index)
                index = closing(text, brace, "{", "}") + 1
            continue
        break
    while True:
        rest = MODIFIER.match(text, index)
        if not rest:
            return index
        index = rest.end()
        if index < len(text) and text[index] in "({":
            pair = ("(", ")") if text[index] == "(" else ("{", "}")
            index = closing(text, index, *pair) + 1


def icononly(path, text):
    for match in ICON_ONLY.finditer(text):
        if exempt(text, match.start()):
            continue
        if not NAMED.search(text, match.start(), chain_end(text, match.end())):
            yield f"{path}:{line_of(text, match.start())}: botón de solo ícono sin .help ni accessibilityLabel"


def main():
    sources, check = pathlib.Path(sys.argv[1]), sys.argv[2]
    run = {"dialogs": dialogs, "toolbar": toolbar, "icononly": icononly}[check]
    for path in sorted(sources.rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for finding in run(path.relative_to(sources), text):
            print(finding)


main()
