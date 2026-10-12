#!/usr/bin/python3
"""GTK4/libadwaita window for the AppIndicator prototype (#734).

Same content as the GNOME extension popover: it shows what model.mjs returns and runs
refresh.mjs for the two buttons. Opening the window reads stored data only.
Run as a separate process from tray.py: AppIndicator needs GTK3, this needs GTK4.
"""
import json
import subprocess
import sys
import threading
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gtk  # noqa: E402

HELPERS = Path(__file__).resolve().parent.parent


def run_node(script: str, *args: str) -> str:
    """Run a helper and return stdout; empty string on failure."""
    proc = subprocess.run(["node", str(HELPERS / script), *args], capture_output=True, text=True)
    return proc.stdout if proc.returncode == 0 else ""


class Window(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="claudestatus", default_width=460)
        self.blocks = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        buttons = Gtk.Box(spacing=8, halign=Gtk.Align.END)
        for title, kind in (("Refresh usage", "usage"), ("Refresh billing", "billing")):
            button = Gtk.Button(label=title)
            button.connect("clicked", self.on_refresh, kind)
            buttons.append(button)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin_top=12,
                       margin_bottom=12, margin_start=12, margin_end=12)
        root.append(self.blocks)
        root.append(buttons)
        view = Adw.ToolbarView(content=root)
        view.add_top_bar(Adw.HeaderBar())
        self.set_content(view)
        self.reload()

    def on_refresh(self, button, kind):
        button.set_sensitive(False)

        def work():
            run_node("refresh.mjs", kind)
            GLib.idle_add(self.done, button)

        threading.Thread(target=work, daemon=True).start()

    def done(self, button):
        button.set_sensitive(True)
        self.reload()
        return False

    def reload(self):
        while child := self.blocks.get_first_child():
            self.blocks.remove(child)
        out = run_node("model.mjs")
        model = json.loads(out) if out else {"accounts": []}
        if not model["accounts"]:
            self.blocks.append(Gtk.Label(label="No data yet: press Refresh usage"))
        for account in model["accounts"]:
            self.blocks.append(Gtk.Label(label=account["text"], xalign=0, css_classes=["monospace"]))


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id="dev.dotfiles.ClaudestatusBar")

    def do_activate(self):
        (self.props.active_window or Window(self)).present()


if __name__ == "__main__":
    sys.exit(App().run(None))
