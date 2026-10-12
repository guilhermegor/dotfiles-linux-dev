#!/usr/bin/python3
"""AppIndicator tray icon for the #734 prototype.

Shows the recommended account's session % next to the icon (updated every 60 s from stored
data only) and opens window.py on click. GTK3 + Ayatana here, GTK4 in window.py: the two
toolkits cannot share a process.
"""
import json
import subprocess
import sys
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3 as AppIndicator  # noqa: E402
from gi.repository import GLib, Gtk  # noqa: E402

HERE = Path(__file__).resolve().parent
MODEL = HERE.parent / "model.mjs"
POLL_SECONDS = 60


def bar_text() -> str:
    proc = subprocess.run(["node", str(MODEL)], capture_output=True, text=True)
    return json.loads(proc.stdout)["bar"] if proc.returncode == 0 and proc.stdout else "—"


def main() -> None:
    indicator = AppIndicator.Indicator.new(
        "claudestatus-bar", "utilities-system-monitor-symbolic",
        AppIndicator.IndicatorCategory.APPLICATION_STATUS)
    indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)

    menu = Gtk.Menu()
    open_item = Gtk.MenuItem(label="Open claudestatus")
    open_item.connect("activate", lambda _: subprocess.Popen(["/usr/bin/python3", str(HERE / "window.py")]))
    quit_item = Gtk.MenuItem(label="Quit")
    quit_item.connect("activate", lambda _: Gtk.main_quit())
    for item in (open_item, quit_item):
        menu.append(item)
    menu.show_all()
    indicator.set_menu(menu)
    indicator.set_secondary_activate_target(open_item)

    def update() -> bool:
        indicator.set_label(bar_text(), "100%")
        return True

    update()
    GLib.timeout_add_seconds(POLL_SECONDS, update)
    Gtk.main()


if __name__ == "__main__":
    sys.exit(main())
