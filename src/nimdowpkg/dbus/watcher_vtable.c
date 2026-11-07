/* The org.kde.StatusNotifierWatcher vtable. sd-bus vtables are built with
 * C macros, so this is the one part that is easier in C than in Nim. All the
 * behaviour lives in Nim (src/nimdowpkg/tray/tray.nim): the entries below only
 * point at the exported cdecl callbacks. */

#include <systemd/sd-bus.h>

extern int nimdow_watcher_register_item(sd_bus_message *m, void *userdata, sd_bus_error *err);
extern int nimdow_watcher_register_host(sd_bus_message *m, void *userdata, sd_bus_error *err);
extern int nimdow_watcher_prop_items(sd_bus *bus, const char *path, const char *interface,
    const char *property, sd_bus_message *reply, void *userdata, sd_bus_error *err);
extern int nimdow_watcher_prop_host(sd_bus *bus, const char *path, const char *interface,
    const char *property, sd_bus_message *reply, void *userdata, sd_bus_error *err);
extern int nimdow_watcher_prop_version(sd_bus *bus, const char *path, const char *interface,
    const char *property, sd_bus_message *reply, void *userdata, sd_bus_error *err);

static const sd_bus_vtable watcher_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("RegisterStatusNotifierItem", "s", "", nimdow_watcher_register_item,
                  SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("RegisterStatusNotifierHost", "s", "", nimdow_watcher_register_host,
                  SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_PROPERTY("RegisteredStatusNotifierItems", "as", nimdow_watcher_prop_items, 0,
                    SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("IsStatusNotifierHostRegistered", "b", nimdow_watcher_prop_host, 0,
                    SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("ProtocolVersion", "i", nimdow_watcher_prop_version, 0,
                    SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_SIGNAL("StatusNotifierItemRegistered", "s", 0),
    SD_BUS_SIGNAL("StatusNotifierItemUnregistered", "s", 0),
    SD_BUS_SIGNAL("StatusNotifierHostRegistered", "", 0),
    SD_BUS_VTABLE_END
};

int nimdow_watcher_install(sd_bus *bus, sd_bus_slot **slot, void *userdata) {
    return sd_bus_add_object_vtable(bus, slot, "/StatusNotifierWatcher",
                                    "org.kde.StatusNotifierWatcher", watcher_vtable, userdata);
}
