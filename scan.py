#!/usr/bin/env python3
"""Backend for the io.github.kimm-stensborg.default-apps shell plugin.

Four subcommands, all speaking JSON on stdout:

  scan             every installed desktop app + the current default per MIME type
  set APP MIME...  point one or more MIME types at a .desktop id
  resolve INPUT    turn ".md" / "md" / "text/markdown" into a MIME type
  menu             add the plugin's row to the Omarchy menu, once

Kept deliberately dependency-free: the shell calls this as a plain
subprocess and parses the single JSON object it prints.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")


def _env_dir(var, default):
    return os.path.expanduser(os.environ.get(var) or default)


def _env_dirs(var, default):
    raw = os.environ.get(var) or default
    return [os.path.expanduser(p) for p in raw.split(":") if p]


def data_dirs():
    return [_env_dir("XDG_DATA_HOME", HOME + "/.local/share")] + _env_dirs(
        "XDG_DATA_DIRS", "/usr/local/share:/usr/share"
    )


def config_dirs():
    return [_env_dir("XDG_CONFIG_HOME", HOME + "/.config")] + _env_dirs(
        "XDG_CONFIG_DIRS", "/etc/xdg"
    )


def app_dirs():
    return [os.path.join(d, "applications") for d in data_dirs()]


def parse_ini(path):
    """Minimal desktop-file/INI reader: {section: {key: value}}."""
    sections = {}
    current = None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("[") and line.endswith("]"):
                    current = line[1:-1]
                    sections.setdefault(current, {})
                    continue
                if current is None or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                sections[current].setdefault(key.strip(), value.strip())
    except OSError:
        return {}
    return sections


def desktop_id(root, path):
    return os.path.relpath(path, root).replace(os.sep, "-")


def scan_apps():
    """Every Type=Application entry, earlier XDG dirs winning on id collision."""
    apps = {}
    for root in app_dirs():
        if not os.path.isdir(root):
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in filenames:
                if not name.endswith(".desktop"):
                    continue
                path = os.path.join(dirpath, name)
                app_id = desktop_id(root, path)
                if app_id in apps:  # an earlier dir already claimed this id
                    continue
                entry = parse_ini(path).get("Desktop Entry", {})
                if entry.get("Type", "Application") != "Application":
                    continue
                if entry.get("Hidden", "").lower() == "true":
                    continue
                if not entry.get("Exec"):
                    continue
                mimes = [m for m in entry.get("MimeType", "").split(";") if m]
                apps[app_id] = {
                    "id": app_id,
                    "name": entry.get("Name") or app_id[:-8],
                    "icon": entry.get("Icon", ""),
                    "generic": entry.get("GenericName", ""),
                    "exec": entry.get("Exec", ""),
                    "mimes": mimes,
                    "terminal": entry.get("Terminal", "").lower() == "true",
                    "noDisplay": entry.get("NoDisplay", "").lower() == "true",
                }
    return apps


def subclass_parents():
    """child -> [parent] from shared-mime-info, so text/markdown knows about text/plain."""
    parents = {}
    for root in data_dirs():
        path = os.path.join(root, "mime", "subclasses")
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    parts = line.split()
                    if len(parts) == 2:
                        parents.setdefault(parts[0], []).append(parts[1])
        except OSError:
            continue
    return parents


def ancestry(mime, parents, seen=None):
    """The mime itself followed by its parents, breadth-first, no repeats."""
    if seen is None:
        seen = []
    if mime in seen:
        return seen
    seen.append(mime)
    for parent in parents.get(mime, []):
        ancestry(parent, parents, seen)
    return seen


def mimeapps_files():
    """Every mimeapps.list in XDG lookup order (most specific first)."""
    desktops = [
        d
        for d in (os.environ.get("XDG_CURRENT_DESKTOP") or "").split(":")
        if d
    ]
    out = []
    for base in config_dirs() + app_dirs():
        for desktop in desktops:
            out.append(os.path.join(base, "%s-mimeapps.list" % desktop.lower()))
        out.append(os.path.join(base, "mimeapps.list"))
    return out


def semicolon_list(value):
    return [v for v in (value or "").split(";") if v]


def read_associations(apps):
    """Walk mimeapps.list files once, collecting defaults / added / removed."""
    defaults = {}   # mime -> app id (first file to name a valid app wins)
    added = {}      # mime -> [app id]
    removed = {}    # mime -> set(app id)
    for path in mimeapps_files():
        sections = parse_ini(path)
        for mime, value in sections.get("Default Applications", {}).items():
            for app_id in semicolon_list(value):
                if app_id in apps and mime not in defaults:
                    defaults[mime] = app_id
                    break
        for mime, value in sections.get("Added Associations", {}).items():
            for app_id in semicolon_list(value):
                if app_id in apps and app_id not in added.setdefault(mime, []):
                    added[mime].append(app_id)
        for mime, value in sections.get("Removed Associations", {}).items():
            removed.setdefault(mime, set()).update(semicolon_list(value))
    return defaults, added, removed


def read_mimeinfo_cache(apps):
    """mime -> [app id] from the per-directory mimeinfo.cache indexes."""
    cache = {}
    for root in app_dirs():
        sections = parse_ini(os.path.join(root, "mimeinfo.cache"))
        for mime, value in sections.get("MIME Cache", {}).items():
            for app_id in semicolon_list(value):
                if app_id in apps and app_id not in cache.setdefault(mime, []):
                    cache[mime].append(app_id)
    return cache


def cmd_scan():
    apps = scan_apps()
    parents = subclass_parents()
    defaults, added, removed = read_associations(apps)
    cache = read_mimeinfo_cache(apps)

    # Declared handlers per mime: MimeType= lines, plus explicit additions,
    # minus explicit removals. Recorded flat; inheritance is applied by the
    # caller against `parents` so it can label an inherited match.
    handlers = {}
    for app_id, app in apps.items():
        for mime in app["mimes"]:
            handlers.setdefault(mime, []).append(app_id)
    for mime, ids in cache.items():
        for app_id in ids:
            if app_id not in handlers.setdefault(mime, []):
                handlers[mime].append(app_id)
    for mime, ids in added.items():
        for app_id in ids:
            if app_id not in handlers.setdefault(mime, []):
                handlers[mime].append(app_id)
    for mime, gone in removed.items():
        if mime in handlers:
            handlers[mime] = [a for a in handlers[mime] if a not in gone]

    json.dump(
        {
            "apps": apps,
            "defaults": defaults,
            "handlers": handlers,
            "parents": parents,
        },
        sys.stdout,
    )
    print()


def cmd_set(argv):
    if len(argv) < 2:
        json.dump({"ok": False, "error": "usage: set APP.desktop MIME..."}, sys.stdout)
        print()
        return 2
    app_id = argv[0]
    if not app_id.endswith(".desktop"):
        app_id += ".desktop"
    mimes = argv[1:]
    proc = subprocess.run(
        ["xdg-mime", "default", app_id] + mimes,
        capture_output=True,
        text=True,
    )
    ok = proc.returncode == 0
    json.dump(
        {
            "ok": ok,
            "app": app_id,
            "mimes": mimes,
            "error": (proc.stderr or proc.stdout).strip() if not ok else "",
        },
        sys.stdout,
    )
    print()
    return 0 if ok else 1


def glob_matches(ext):
    """MIME types whose *.EXT glob matches, best weight first, from shared-mime-info."""
    scored = {}
    pattern = "*." + ext
    for root in data_dirs():
        path = os.path.join(root, "mime", "globs2")
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    parts = line.split(":")
                    if len(parts) < 3:
                        continue
                    try:
                        weight = int(parts[0])
                    except ValueError:
                        continue
                    mime, glob = parts[1], parts[2]
                    if glob.lower() != pattern:
                        continue
                    if scored.get(mime, -1) < weight:
                        scored[mime] = weight
        except OSError:
            continue
    return [m for m, _w in sorted(scored.items(), key=lambda kv: (-kv[1], kv[0]))]


def cmd_resolve(argv):
    """Accept a MIME type, a bare extension, or a filename."""
    raw = (argv[0] if argv else "").strip()
    if not raw:
        json.dump({"ok": False, "error": "nothing to resolve"}, sys.stdout)
        print()
        return 2

    # A slash means the user typed the MIME type itself; take it as given so
    # a type this machine has no glob for can still be assigned.
    if "/" in raw and " " not in raw:
        json.dump({"ok": True, "mime": raw, "alternates": [], "source": "literal"}, sys.stdout)
        print()
        return 0

    ext = raw.lower().split("/")[-1]
    if "." in ext:
        ext = ext.rsplit(".", 1)[-1]
    ext = ext.lstrip("*").lstrip(".")
    if not ext:
        json.dump({"ok": False, "error": "not a MIME type or extension"}, sys.stdout)
        print()
        return 2

    matches = glob_matches(ext)
    if not matches:
        json.dump(
            {"ok": False, "error": "no MIME type registered for .%s" % ext},
            sys.stdout,
        )
        print()
        return 1
    json.dump(
        {"ok": True, "mime": matches[0], "alternates": matches[1:], "ext": ext, "source": "extension"},
        sys.stdout,
    )
    print()
    return 0


PLUGIN_ID = "io.github.kimm-stensborg.default-apps"
MENU_ID = "setup.default.filetypes"
# The same marker shape the Plugin Manager's install.sh puts above its row, so
# every row a plugin of ours wrote is labelled the same way.
MENU_MARKER = "  // ── Default Applications (%s)" % PLUGIN_ID
MENU_ENTRY = {
    "icon": "󰈔",
    "label": "Filetypes",
    "description": "Choose which application opens each filetype",
    "aliases": ["mimetypes", "default-apps", "associations"],
    # Hides the row once `omarchy plugin remove` has deleted the folder, so a
    # removed plugin never leaves behind a row that opens nothing.
    "when": "[[ -d ~/.config/omarchy/plugins/%s ]]" % PLUGIN_ID,
    "action": "omarchy-shell shell summon %s '{}'" % PLUGIN_ID,
}
LINE_COMMENT = re.compile(r"^\s*//[^\n]*(\n|$)", re.M)


def menu_path():
    # The exact path Omarchy's Menu.qml reads; it does not honour XDG_CONFIG_HOME.
    return os.path.join(HOME, ".config", "omarchy", "extensions", "omarchy-menu.jsonc")


def menu_state_path():
    return os.path.join(
        _env_dir("XDG_STATE_HOME", HOME + "/.local/state"), "omarchy-default-apps", "menu-entry"
    )


def parse_menu(text):
    """The menu file as Omarchy's MenuModel.js reads it, or None where it reads
    nothing. Mirrors its stripJsonc exactly: whole-line // comments and
    trailing commas go, and no other JSONC is understood."""
    stripped = LINE_COMMENT.sub("", text)
    stripped = re.sub(r",(\s*[}\]])", r"\1", stripped)
    if not stripped.strip():
        return {}
    try:
        parsed = json.loads(stripped)
    except ValueError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _significant(line):
    stripped = line.strip()
    return bool(stripped) and not stripped.startswith("//")


def insert_menu_row(text, row):
    """text with MENU_MARKER and row as the last entries of its top-level
    object, or None when its last significant line does not close one."""
    lines = text.split("\n")
    close = next((i for i in reversed(range(len(lines))) if _significant(lines[i])), None)
    if close is None or not lines[close].rstrip().endswith("}"):
        return None
    last = lines[close].rstrip()
    head = lines[:close]
    # A one-line "{}", or an entry sharing the closing brace's line, keeps
    # what comes before the brace.
    if last[:-1].strip():
        head.append(last[:-1].rstrip())
    prev = next((i for i in reversed(range(len(head))) if _significant(head[i])), None)
    if prev is not None and not head[prev].rstrip().endswith((",", "{")):
        head[prev] = head[prev].rstrip() + ","
    if head and _significant(head[-1]) and not head[-1].rstrip().endswith("{"):
        head.append("")
    return "\n".join(head + [MENU_MARKER, row, "}"] + lines[close + 1:])


def remember_menu_row(state):
    """Note that the row has been in the menu, so deleting it is final."""
    if os.path.exists(state):
        return
    os.makedirs(os.path.dirname(state), exist_ok=True)
    with open(state, "w", encoding="utf-8") as fh:
        fh.write(time.strftime("%Y-%m-%dT%H:%M:%S%z") + "\n")


def cmd_menu():
    """Put the plugin under Setup → Defaults, once, on its first start.

    The file is left alone when a row for the plugin is already there, when
    an earlier run added one that has since been deleted, and whenever the
    edit would change anything besides adding the row."""
    path = menu_path()
    state = menu_state_path()

    def reply(ok, status, error=""):
        json.dump({"ok": ok, "status": status, "path": path, "error": error}, sys.stdout)
        print()
        return 0 if ok else 1

    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
        existed = True
    except FileNotFoundError:
        text, existed = "", False
    except (OSError, UnicodeDecodeError) as err:
        return reply(False, "unreadable", str(err))

    current = parse_menu(text)
    if current is None:
        return reply(False, "unreadable", "the Omarchy menu cannot parse %s" % path)
    if MENU_ID in current or PLUGIN_ID in text:
        try:
            remember_menu_row(state)
        except OSError:
            pass
        return reply(True, "present")
    if os.path.exists(state):
        return reply(True, "declined")
    if isinstance(current.get("items"), dict):
        return reply(False, "unsupported", 'rows in %s are nested under "items"' % path)

    if not LINE_COMMENT.sub("", text).strip():
        text += ("" if not text or text.endswith("\n") else "\n") + "{\n}\n"
    row = "  %s:%s," % (
        json.dumps(MENU_ID),
        json.dumps(MENU_ENTRY, ensure_ascii=False, separators=(",", ":")),
    )
    updated = insert_menu_row(text, row)
    # The one guarantee that matters: the menu reads everything it read
    # before, plus this row, and nothing else changed.
    if updated is None or parse_menu(updated) != dict(current, **{MENU_ID: MENU_ENTRY}):
        return reply(False, "unsupported", "cannot add a row to %s without changing the rest" % path)

    # Write to the real file behind a symlink rather than replacing the link,
    # so a dotfile manager's link survives.
    target = os.path.realpath(path)
    try:
        os.makedirs(os.path.dirname(target), exist_ok=True)
        tmp = target + ".default-apps.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(updated)
        if existed:
            shutil.copymode(target, tmp)
            shutil.copy2(target, "%s.bak.%d" % (target, int(time.time())))
        os.replace(tmp, target)
        remember_menu_row(state)
    except OSError as err:
        return reply(False, "error", str(err))
    return reply(True, "added")


def main(argv):
    if not argv:
        print("usage: scan.py {scan|set|resolve|menu} ...", file=sys.stderr)
        return 2
    command, rest = argv[0], argv[1:]
    if command == "scan":
        cmd_scan()
        return 0
    if command == "set":
        return cmd_set(rest)
    if command == "resolve":
        return cmd_resolve(rest)
    if command == "menu":
        return cmd_menu()
    print("unknown command: %s" % command, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
