namespace Singularity.Nearby {

    public delegate void NotificationAction(string action);
    public delegate void NotificationReply(string text);
    public delegate void NotificationClosed(uint reason);

    private class NotificationHandlers {
        public NotificationAction? on_action;
        public NotificationReply? on_reply;
        public NotificationClosed? on_closed;
    }

    public class Desktop : Object {
        public const string APP_ID = "dev.sinty.Nearby";
        private const string BUS = "org.freedesktop.Notifications";
        private const string PATH = "/org/freedesktop/Notifications";

        private DBusConnection bus;
        private Gee.HashMap<uint32, NotificationHandlers> handlers = new Gee.HashMap<uint32, NotificationHandlers>();

        public Desktop(DBusConnection bus) {
            this.bus = bus;
            bus.signal_subscribe(null, BUS, null, PATH, null, DBusSignalFlags.NONE, on_signal);
        }

        private void on_signal(DBusConnection conn, string? sender, string path, string iface, string name, Variant parameters) {
            if (name == "ActionInvoked") {
                uint32 id;
                string key;
                parameters.get("(us)", out id, out key);
                var h = handlers[id];
                if (h != null && h.on_action != null) h.on_action(key);
            } else if (name == "NotificationReplied") {
                uint32 id;
                string text;
                parameters.get("(us)", out id, out text);
                var h = handlers[id];
                if (h != null && h.on_reply != null) h.on_reply(text);
            } else if (name == "NotificationClosed") {
                uint32 id;
                uint32 reason;
                parameters.get("(uu)", out id, out reason);
                var h = handlers[id];
                handlers.unset(id);
                if (h != null && h.on_closed != null) h.on_closed(reason);
            }
        }

        public async uint32 send_notification(string app_name, string icon, string summary, string body, string[] actions,
                                   HashTable<string, Variant>? extra_hints = null, uint32 replaces = 0,
                                   owned NotificationAction? on_action = null, owned NotificationReply? on_reply = null,
                                   owned NotificationClosed? on_closed = null, int timeout = -1) {
            var hints = new VariantBuilder(new VariantType("a{sv}"));
            hints.add("{sv}", "desktop-entry", new Variant.string(APP_ID));
            if (extra_hints != null) {
                foreach (string k in extra_hints.get_keys()) hints.add("{sv}", k, extra_hints[k]);
            }
            try {
                var reply = yield bus.call(BUS, PATH, BUS, "Notify",
                    new Variant("(susss^as@a{sv}i)", app_name, replaces, icon, summary, body, actions, hints.end(), timeout),
                    new VariantType("(u)"), DBusCallFlags.NONE, 5000, null);
                uint32 id;
                reply.get("(u)", out id);
                var h = new NotificationHandlers();
                h.on_action = (owned) on_action;
                h.on_reply = (owned) on_reply;
                h.on_closed = (owned) on_closed;
                handlers[id] = h;
                return id;
            } catch (Error e) {
                debug("nearby: no notification server: %s", e.message);
                return 0;
            }
        }

        public void close(uint32 id) {
            if (id == 0) return;
            bus.call.begin(BUS, PATH, BUS, "CloseNotification", new Variant("(u)", id), null, DBusCallFlags.NONE, 5000, null);
        }

        public void forget(uint32 id) {
            handlers.unset(id);
        }

        public static void open_uri(string uri) {
            try {
                AppInfo.launch_default_for_uri(uri, null);
            } catch (Error e) {
                warning("nearby: cannot open %s: %s", uri, e.message);
            }
        }

        public void show_in_files(string uri) {
            string[] items = { uri };
            bus.call.begin("org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1", "ShowItems",
                new Variant("(^ass)", items, ""), null, DBusCallFlags.NONE, 5000, null, (o, r) => {
                    try {
                        bus.call.end(r);
                    } catch (Error e) {
                        var parent = File.new_for_uri(uri).get_parent();
                        if (parent != null) open_uri(parent.get_uri());
                    }
                });
        }

        public static int battery_level(out bool charging) {
            charging = false;
            int total = -1;
            try {
                string root = Environment.get_variable("SINGULARITY_NEARBY_POWER_SUPPLY") ?? "/sys/class/power_supply";
                var dir = Dir.open(root);
                string? n;
                while ((n = dir.read_name()) != null) {
                    string base_path = Path.build_filename(root, n);
                    string type;
                    if (!FileUtils.get_contents(Path.build_filename(base_path, "type"), out type) || type.strip() != "Battery") continue;
                    string cap, status;
                    if (FileUtils.get_contents(Path.build_filename(base_path, "capacity"), out cap)) total = int.parse(cap.strip());
                    if (FileUtils.get_contents(Path.build_filename(base_path, "status"), out status)) charging = status.strip() == "Charging" || status.strip() == "Full";
                    break;
                }
            } catch (Error e) {
            }
            return total;
        }
    }
}
