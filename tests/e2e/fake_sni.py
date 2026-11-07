#!/usr/bin/env python3
"""Test fixture for the nimdow system tray: a fake StatusNotifierItem (and,
with --watcher, a fake StatusNotifierWatcher). Uses the session bus
(DBUS_SESSION_BUS_ADDRESS), so run it inside `dbus-run-session`.

  fake_sni.py item    --variant name|pixmap --log FILE [--id ID] [--theme-path DIR] [--item-is-menu] [--no-menu]
  fake_sni.py watcher [--log FILE]

Item behaviour:
  * IconName "dialog-information" (variant name; lives in AdwaitaLegacy, found
    through Adwaita's Inherits) or an IconPixmap of 32x32 red|blue (variant
    pixmap).
  * Activate/SecondaryActivate/ContextMenu/Scroll append a line to the log.
  * SIGUSR1: IconName/pixmap changes (name -> "audio-headphones", an SVG;
    pixmap -> green|yellow) and NewIcon is emitted.
  * SIGUSR2: Status toggles Active <-> Passive and NewStatus is emitted.
  * Exports com.canonical.dbusmenu at /MenuBar (Menu property):
        Open (1), separator (7), "Toggle me" checkmark (2), Disabled (8, enabled=false),
        More (3, submenu: Sub A 4, Sub B 5), Quit (6).
    Every Event/AboutToShow call is logged ("ID MenuEvent <id> <name>",
    "ID MenuAboutToShow <id>"). Clicking "Toggle me" flips its state and emits
    ItemsPropertiesUpdated. --item-is-menu sets ItemIsMenu=true, --no-menu Menu="/".
Prints "READY" on stdout once registered.
"""
import argparse
import os
import signal
import sys
import time

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

WATCHER = "org.kde.StatusNotifierWatcher"
WATCHER_PATH = "/StatusNotifierWatcher"

ITEM_XML = """
<node>
  <interface name="org.kde.StatusNotifierItem">
    <property name="Category" type="s" access="read"/>
    <property name="Id" type="s" access="read"/>
    <property name="Title" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="IconName" type="s" access="read"/>
    <property name="IconPixmap" type="a(iiay)" access="read"/>
    <property name="AttentionIconName" type="s" access="read"/>
    <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
    <property name="IconThemePath" type="s" access="read"/>
    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    <property name="ItemIsMenu" type="b" access="read"/>
    <property name="Menu" type="o" access="read"/>
    <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
    <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
    <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
    <method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
    <signal name="NewIcon"/>
    <signal name="NewAttentionIcon"/>
    <signal name="NewTitle"/>
    <signal name="NewStatus"><arg type="s"/></signal>
    <signal name="NewToolTip"/>
  </interface>
</node>"""

MENU_XML = """
<node>
  <interface name="com.canonical.dbusmenu">
    <method name="GetLayout">
      <arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
      <arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/>
    </method>
    <method name="Event">
      <arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/>
    </method>
    <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
    <property name="Version" type="u" access="read"/>
    <property name="Status" type="s" access="read"/>
    <signal name="ItemsPropertiesUpdated">
      <arg type="a(ia{sv})"/><arg type="a(ias)"/>
    </signal>
    <signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
  </interface>
</node>"""

WATCHER_XML = """
<node>
  <interface name="org.kde.StatusNotifierWatcher">
    <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
    <method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <property name="ProtocolVersion" type="i" access="read"/>
    <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
    <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
    <signal name="StatusNotifierHostRegistered"/>
  </interface>
</node>"""


def pixmap(left, right):
    """A 32x32 ARGB32 (network byte order) pixmap: left half, right half."""
    data = bytearray()
    for _y in range(32):
        for x in range(32):
            data += bytes(left if x < 16 else right)
    return GLib.Variant("a(iiay)", [(32, 32, bytes(data))])


class Logger:
    def __init__(self, path):
        self.path = path

    def __call__(self, line):
        if self.path:
            with open(self.path, "a") as f:
                f.write(line + "\n")


def log_out(msg):
    print(msg, flush=True)


class Item:
    def __init__(self, conn, args, log):
        self.conn, self.args, self.log = conn, args, log
        self.status = "Active"
        self.toggled = False
        self.revision = 1
        self.changed_icon = False
        if args.variant == "name":
            self.icon_name = "dialog-information"
            self.icon_pixmap = GLib.Variant("a(iiay)", [])
        else:
            self.icon_name = ""
            self.icon_pixmap = pixmap((255, 255, 0, 0), (255, 0, 0, 255))
        self.node = Gio.DBusNodeInfo.new_for_xml(ITEM_XML)
        self.reg = conn.register_object(
            "/StatusNotifierItem", self.node.interfaces[0], self.on_call, self.on_get, None)
        self.menu_node = Gio.DBusNodeInfo.new_for_xml(MENU_XML)
        conn.register_object(
            "/MenuBar", self.menu_node.interfaces[0], self.on_menu_call, self.on_menu_get, None)

    def on_get(self, conn, sender, path, iface, prop):
        a = self.args
        values = {
            "Category": GLib.Variant("s", "ApplicationStatus"),
            "Id": GLib.Variant("s", a.id),
            "Title": GLib.Variant("s", a.id + " title"),
            "Status": GLib.Variant("s", self.status),
            "IconName": GLib.Variant("s", self.icon_name),
            "IconPixmap": self.icon_pixmap,
            "AttentionIconName": GLib.Variant("s", ""),
            "AttentionIconPixmap": GLib.Variant("a(iiay)", []),
            "IconThemePath": GLib.Variant("s", a.theme_path or ""),
            "ToolTip": GLib.Variant("(sa(iiay)ss)", ("", [], a.id + " tip", "")),
            "ItemIsMenu": GLib.Variant("b", bool(a.item_is_menu)),
            "Menu": GLib.Variant("o", "/" if a.no_menu else "/MenuBar"),
        }
        return values.get(prop)

    def on_call(self, conn, sender, path, iface, method, params, invocation):
        args = params.unpack()
        if method == "Scroll":
            self.log(f"{self.args.id} Scroll {args[0]} {args[1]}")
        else:
            self.log(f"{self.args.id} {method} {args[0]} {args[1]}")
        invocation.return_value(None)

    def on_menu_get(self, conn, sender, path, iface, prop):
        return {"Version": GLib.Variant("u", 3), "Status": GLib.Variant("s", "normal")}.get(prop)

    def menu_props(self, i):
        """Properties of a menu entry (a{sv})."""
        v = GLib.Variant
        table = {
            1: {"label": v("s", "_Open")},
            7: {"type": v("s", "separator")},
            2: {"label": v("s", "Toggle me"), "toggle-type": v("s", "checkmark"),
                "toggle-state": v("i", 1 if self.toggled else 0)},
            8: {"label": v("s", "Disabled"), "enabled": v("b", False)},
            3: {"label": v("s", "More"), "children-display": v("s", "submenu")},
            4: {"label": v("s", "Sub A")},
            5: {"label": v("s", "Sub B"), "icon-name": v("s", "dialog-information")},
            6: {"label": v("s", "Quit __now")},
        }
        return table[i]

    def on_menu_call(self, conn, sender, path, iface, method, params, invocation):
        if method == "GetLayout":
            def entry(i, kids=()):
                return GLib.Variant("(ia{sv}av)", (i, self.menu_props(i),
                                                  list(kids)))
            more = entry(3, [entry(4), entry(5)])
            top = [entry(1), entry(7), entry(2), entry(8), more, entry(6)]
            root = (0, {"children-display": GLib.Variant("s", "submenu")},
                    top)
            invocation.return_value(GLib.Variant("(u(ia{sv}av))", (self.revision, root)))
        elif method == "Event":
            mid, name = params.unpack()[0], params.unpack()[1]
            self.log(f"{self.args.id} MenuEvent {mid} {name}")
            if mid == 2 and name == "clicked":
                self.toggled = not self.toggled
                conn.emit_signal(
                    None, "/MenuBar", "com.canonical.dbusmenu", "ItemsPropertiesUpdated",
                    GLib.Variant("(a(ia{sv})a(ias))", ([(2, self.menu_props(2))], [])))
            invocation.return_value(None)
        elif method == "AboutToShow":
            self.log(f"{self.args.id} MenuAboutToShow {params.unpack()[0]}")
            invocation.return_value(GLib.Variant("(b)", (False,)))
        else:
            invocation.return_value(None)

    def emit(self, name, params=None):
        self.conn.emit_signal(None, "/StatusNotifierItem", "org.kde.StatusNotifierItem", name, params)

    def usr1(self):
        self.changed_icon = True
        if self.args.variant == "name":
            self.icon_name = "audio-headphones"
        else:
            self.icon_pixmap = pixmap((255, 0, 200, 0), (255, 255, 255, 0))
        self.emit("NewIcon")

    def usr2(self):
        self.status = "Passive" if self.status == "Active" else "Active"
        self.emit("NewStatus", GLib.Variant("(s)", (self.status,)))


class Watcher:
    def __init__(self, conn, log):
        self.conn, self.log = conn, log
        self.items = []
        self.hosts = []
        self.node = Gio.DBusNodeInfo.new_for_xml(WATCHER_XML)
        conn.register_object(WATCHER_PATH, self.node.interfaces[0], self.on_call, self.on_get, None)

    def on_get(self, conn, sender, path, iface, prop):
        return {
            "RegisteredStatusNotifierItems": GLib.Variant("as", self.items),
            "IsStatusNotifierHostRegistered": GLib.Variant("b", bool(self.hosts)),
            "ProtocolVersion": GLib.Variant("i", 0),
        }.get(prop)

    def on_call(self, conn, sender, path, iface, method, params, invocation):
        arg = params.unpack()[0]
        if method == "RegisterStatusNotifierItem":
            spec = (sender + arg) if arg.startswith("/") else (arg + "/StatusNotifierItem" if "/" not in arg else arg)
            self.log(f"watcher RegisterStatusNotifierItem {spec}")
            if spec not in self.items:
                self.items.append(spec)
                conn.emit_signal(None, WATCHER_PATH, WATCHER, "StatusNotifierItemRegistered",
                                 GLib.Variant("(s)", (spec,)))
            # Items vanish with their bus name.
            bus_name = spec.split("/")[0]
            Gio.bus_watch_name_on_connection(
                conn, bus_name, Gio.BusNameWatcherFlags.NONE, None,
                lambda c, n, s=spec: self.gone(s))
        else:
            self.log(f"watcher RegisterStatusNotifierHost {arg}")
            self.hosts.append(arg)
            conn.emit_signal(None, WATCHER_PATH, WATCHER, "StatusNotifierHostRegistered", None)
        invocation.return_value(None)

    def gone(self, spec):
        if spec in self.items:
            self.items.remove(spec)
            self.conn.emit_signal(None, WATCHER_PATH, WATCHER, "StatusNotifierItemUnregistered",
                                  GLib.Variant("(s)", (spec,)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["item", "watcher"])
    ap.add_argument("--variant", choices=["name", "pixmap"], default="name")
    ap.add_argument("--log", default="")
    ap.add_argument("--id", default="")
    ap.add_argument("--theme-path", default="")
    ap.add_argument("--item-is-menu", action="store_true")
    ap.add_argument("--no-menu", action="store_true")
    args = ap.parse_args()
    if not args.id:
        args.id = f"fake-{args.variant}"
    log = Logger(args.log)
    if "DBUS_SESSION_BUS_ADDRESS" not in os.environ:
        sys.exit("fake_sni: no DBUS_SESSION_BUS_ADDRESS (run inside dbus-run-session)")

    conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    loop = GLib.MainLoop()

    if args.mode == "watcher":
        w = Watcher(conn, log)
        Gio.bus_own_name_on_connection(
            conn, WATCHER, Gio.BusNameOwnerFlags.NONE,
            lambda c, n: log_out("READY"), lambda c, n: sys.exit("could not own the watcher name"))
        loop.run()
        return

    item = Item(conn, args, log)
    name = f"org.kde.StatusNotifierItem-{os.getpid()}-1"
    Gio.bus_own_name_on_connection(conn, name, Gio.BusNameOwnerFlags.NONE, None, None)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, lambda: item.usr1() or True)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR2, lambda: item.usr2() or True)

    # The watcher may appear later (nimdow starts it): keep trying.
    deadline = time.time() + 20

    def register():
        try:
            conn.call_sync(WATCHER, WATCHER_PATH, WATCHER, "RegisterStatusNotifierItem",
                           GLib.Variant("(s)", (name,)), None, Gio.DBusCallFlags.NONE, 2000, None)
            log_out("READY")
            return False
        except GLib.Error:
            if time.time() > deadline:
                sys.exit("fake_sni: no watcher")
            return True

    if register():
        GLib.timeout_add(200, register)
    loop.run()


if __name__ == "__main__":
    main()
