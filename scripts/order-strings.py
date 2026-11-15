#!/usr/bin/env python3
"""Keeps Localizable.strings ordered by area of the app without changing any key or value.

Usage: scripts/order-strings.py [--write | --count | --check]
  --write  rewrites the file in its canonical order (areas, then first-level prefix, then the
           second segment in order of first appearance; keys keep their relative order).
  --count  prints how many keys are out of their canonical place (lint-ui.sh caps it at 0).
  --check  exits 1 when the file is not in canonical order (default).

A key whose first-level prefix belongs to no area is an error: add the prefix to AREAS.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STRINGS = ROOT / "native/Sources/ButakeStack/Resources/es.lproj/Localizable.strings"

# (header, first-level prefixes in order). A prefix ending in "*" matches every key that
# starts with it (the update and theme keys have no dot).
AREAS = [
    ("Base: nombre, textos comunes y estados",
     ["app", "version", "buildNumber", "common", "value", "toast", "filter", "snippet", "state",
      "busy", "lifecycle", "engine", "daemon", "keychain"]),
    ("Ventana: barra lateral, rutas, menús, paleta y barra de menús",
     ["route", "sidebar", "menu", "palette", "panel", "stackState", "favorites"]),
    ("Inicio", ["home"]),
    ("Asistente de configuración y activación",
     ["setup", "assistant", "activation", "profile", "profiles"]),
    ("Actualizaciones", ["update*"]),
    ("Proyectos: lista, página y ajustes",
     ["site", "sites", "project", "kind", "unserved", "tech", "groups", "import", "missing",
      "attention", "note", "commands", "process", "task", "branch", "worktree", "editor",
      "watch"]),
    ("Proyectos: nuevo proyecto", ["new", "place"]),
    ("Proyectos: renombrar y mover", ["rename", "move"]),
    ("Proyectos: varias partes", ["composite"]),
    ("Proyectos: compartir y dirección fija", ["share"]),
    ("Entornos", ["env"]),
    ("Servicios", ["category", "services", "broadcasting", "unavailable"]),
    ("Servicios: extensiones", ["ext"]),
    ("Lenguajes", ["language", "runtimes", "versions", "php", "xdebug", "python", "rust", "swift",
                   "terminal"]),
    ("Utilidades", ["utilities", "tools", "tool", "toolDetail", "toolSource"]),
    ("Instalaciones: progreso y verificación", ["progress", "verify"]),
    ("Herramientas: catálogo y opciones", ["plugin", "plugins", "receiver"]),
    ("Herramienta Git", ["git"]),
    ("Herramienta Terminal", ["ssh"]),
    ("Herramienta Cliente de bases de datos", ["db", "ddl"]),
    ("Herramienta Bóveda", ["vault"]),
    ("Herramienta Correo", ["mail"]),
    ("Herramienta Dumps", ["dumps"]),
    ("Herramienta Registros", ["logs"]),
    ("Herramienta AWS", ["aws"]),
    ("Herramienta Google Cloud", ["gcp"]),
    ("Ajustes", ["settings", "general", "theme*", "keys", "trust", "listener", "mode",
                 "migration", "backup"]),
    ("Errores del motor y de la app", ["error"]),
]

LINE = re.compile(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";$')
COMMENT = re.compile(r"^/\*.*\*/$")


def parse(text):
    pairs = []
    for number, line in enumerate(text.split("\n"), 1):
        if not line.strip() or COMMENT.match(line):
            continue
        match = LINE.match(line)
        if not match:
            sys.exit(f"{STRINGS.name}:{number}: línea que no es clave = valor ni comentario")
        pairs.append((match.group(1), line))
    keys = [key for key, _ in pairs]
    if len(set(keys)) != len(keys):
        duplicated = sorted({key for key in keys if keys.count(key) > 1})
        sys.exit(f"claves repetidas: {', '.join(duplicated)}")
    return pairs


def slot(key):
    """(area, prefix) position of a key, or None when its prefix belongs to no area."""
    first = key.split(".", 1)[0]
    for area, (_, prefixes) in enumerate(AREAS):
        for index, prefix in enumerate(prefixes):
            if prefix.endswith("*") and key.startswith(prefix[:-1]) or prefix == first:
                return area, index
    return None


def canonical(pairs):
    unknown = sorted({key.split(".", 1)[0] for key, _ in pairs if slot(key) is None})
    if unknown:
        sys.exit(f"prefijos sin área en scripts/order-strings.py: {', '.join(unknown)}")
    groups = {}
    for key, line in pairs:
        parts = key.split(".")
        second = parts[1] if len(parts) > 2 else ""
        groups.setdefault(slot(key), {}).setdefault(second, []).append((key, line))
    ordered = []
    for position in sorted(groups):
        for lines in groups[position].values():
            ordered.extend(lines)
    return ordered


def render(ordered):
    out = []
    last_area, last_slot = None, None
    for key, line in ordered:
        position = slot(key)
        if position[0] != last_area:
            if out:
                out.append("")
            out.append(f"/* {AREAS[position[0]][0]} */")
        elif position != last_slot:
            out.append("")
        out.append(line)
        last_area, last_slot = position[0], position
    return "\n".join(out) + "\n"


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    text = STRINGS.read_text(encoding="utf-8")
    pairs = parse(text)
    ordered = canonical(pairs)
    result = render(ordered)
    if mode == "--write":
        STRINGS.write_text(result, encoding="utf-8")
    elif mode == "--count":
        misplaced = sum(1 for (a, _), (b, _) in zip(pairs, ordered) if a != b)
        print(misplaced if misplaced or result == text else 1)
    elif mode == "--check":
        if result != text:
            sys.exit("Localizable.strings no está en orden: corre scripts/order-strings.py --write")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
