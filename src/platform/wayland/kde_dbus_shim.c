// sd-bus vtable for the IPC channel KdeBackend uses to receive output from
// KWin scripts. The vtable struct in <systemd/sd-bus.h> uses bitfields and
// macros that Zig's translate-c can't reproduce, so we build it here in C.

#include <systemd/sd-bus.h>

// Implemented in KdeBackend.zig (export fn).
extern int vitrail_ipc_submit_handler(sd_bus_message *msg, void *userdata, sd_bus_error *err);

static const sd_bus_vtable vitrail_ipc_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("Submit", "s", "", vitrail_ipc_submit_handler, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_VTABLE_END,
};

int vitrail_register_ipc(sd_bus *bus, sd_bus_slot **slot, const char *path, const char *iface, void *userdata) {
    return sd_bus_add_object_vtable(bus, slot, path, iface, vitrail_ipc_vtable, userdata);
}
