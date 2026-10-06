namespace Singularity.Nearby {

    public class LocalMedia : Object {
        private const string PREFIX = "org.mpris.MediaPlayer2.";
        private const string PATH = "/org/mpris/MediaPlayer2";
        private const string PLAYER = "org.mpris.MediaPlayer2.Player";
        public const string[] ACTIONS = { "Play", "Pause", "PlayPause", "Next", "Previous", "Stop" };

        private DBusConnection bus;
        private Gee.HashMap<string, string> owners = new Gee.HashMap<string, string>();
        private Gee.HashMap<string, string> bus_names = new Gee.HashMap<string, string>();

        public signal void changed(string player);

        public LocalMedia(DBusConnection bus) {
            this.bus = bus;
            bus.signal_subscribe(null, "org.freedesktop.DBus.Properties", "PropertiesChanged", PATH, PLAYER, DBusSignalFlags.MATCH_ARG0_NAMESPACE, (c, sender, path, iface, name, parameters) => {
                foreach (var entry in owners.entries) {
                    if (entry.value == sender) {
                        changed(entry.key);
                        return;
                    }
                }
                refresh.begin((o, r) => {
                    refresh.end(r);
                    foreach (var entry in owners.entries) if (entry.value == sender) changed(entry.key);
                });
            });
        }

        public async string[] refresh() {
            owners.clear();
            bus_names.clear();
            string[] result = {};
            try {
                var reply = yield bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames",
                    null, new VariantType("(as)"), DBusCallFlags.NONE, 3000, null);
                string[] all = reply.get_child_value(0).dup_strv();
                foreach (string n in all) {
                    if (!n.has_prefix(PREFIX)) continue;
                    string identity = n.substring(PREFIX.length);
                    string owner = n;
                    try {
                        var id_reply = yield bus.call(n, PATH, "org.freedesktop.DBus.Properties", "Get",
                            new Variant("(ss)", "org.mpris.MediaPlayer2", "Identity"), new VariantType("(v)"), DBusCallFlags.NONE, 2000, null);
                        var v = id_reply.get_child_value(0).get_variant();
                        if (v.is_of_type(VariantType.STRING) && v.get_string() != "") identity = v.get_string();
                        var owner_reply = yield bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
                            new Variant("(s)", n), new VariantType("(s)"), DBusCallFlags.NONE, 2000, null);
                        owner = owner_reply.get_child_value(0).dup_string();
                    } catch (Error e) {
                    }
                    string unique = identity;
                    int i = 2;
                    while (owners.has_key(unique)) unique = "%s %d".printf(identity, i++);
                    owners[unique] = owner;
                    bus_names[unique] = n;
                    result += unique;
                }
            } catch (Error e) {
            }
            return result;
        }

        private string? bus_name(string player) {
            return bus_names[player];
        }

        public async Packet? now_playing(string player) {
            string? n = bus_name(player);
            if (n == null) {
                yield refresh();
                n = bus_name(player);
            }
            if (n == null) return null;
            try {
                var reply = yield bus.call(n, PATH, "org.freedesktop.DBus.Properties", "GetAll",
                    new Variant("(s)", PLAYER), new VariantType("(a{sv})"), DBusCallFlags.NONE, 3000, null);
                var props = reply.get_child_value(0);
                var p = new Packet(Packet.MPRIS);
                p.set_string("player", player);
                var meta = props.lookup_value("Metadata", null);
                string title = "", artist = "", album = "";
                int64 length = 0;
                if (meta != null) {
                    var t = meta.lookup_value("xesam:title", VariantType.STRING);
                    if (t != null) title = t.get_string();
                    var a = meta.lookup_value("xesam:artist", VariantType.STRING_ARRAY);
                    if (a != null) artist = string.joinv(", ", a.dup_strv());
                    var al = meta.lookup_value("xesam:album", VariantType.STRING);
                    if (al != null) album = al.get_string();
                    var len = meta.lookup_value("mpris:length", null);
                    if (len != null && len.is_of_type(VariantType.INT64)) length = len.get_int64() / 1000;
                    else if (len != null && len.is_of_type(VariantType.UINT64)) length = (int64) (len.get_uint64() / 1000);
                }
                p.set_string("title", title);
                p.set_string("artist", artist);
                p.set_string("album", album);
                p.set_int("length", length);
                var status = props.lookup_value("PlaybackStatus", VariantType.STRING);
                p.set_bool("isPlaying", status != null && status.get_string() == "Playing");
                p.set_bool("canPause", bool_prop(props, "CanPause"));
                p.set_bool("canPlay", bool_prop(props, "CanPlay"));
                p.set_bool("canGoNext", bool_prop(props, "CanGoNext"));
                p.set_bool("canGoPrevious", bool_prop(props, "CanGoPrevious"));
                p.set_bool("canSeek", bool_prop(props, "CanSeek"));
                var pos = props.lookup_value("Position", VariantType.INT64);
                p.set_int("pos", pos != null ? pos.get_int64() / 1000 : 0);
                var vol = props.lookup_value("Volume", VariantType.DOUBLE);
                p.set_int("volume", vol != null ? (int64) (vol.get_double() * 100) : 100);
                return p;
            } catch (Error e) {
                return null;
            }
        }

        private static bool bool_prop(Variant props, string key) {
            var v = props.lookup_value(key, VariantType.BOOLEAN);
            return v != null && v.get_boolean();
        }

        public async void control(Packet request) {
            string player = request.get_string("player", "");
            string? n = bus_name(player);
            if (n == null) {
                yield refresh();
                n = bus_name(player);
            }
            if (n == null) return;
            try {
                string? action = request.get_string("action");
                if (action != null && action in ACTIONS) {
                    yield bus.call(n, PATH, PLAYER, action, null, null, DBusCallFlags.NONE, 3000, null);
                }
                if (request.has("setVolume")) {
                    double vol = request.get_int("setVolume", 100) / 100.0;
                    yield bus.call(n, PATH, "org.freedesktop.DBus.Properties", "Set",
                        new Variant("(ssv)", PLAYER, "Volume", new Variant.double(vol.clamp(0.0, 1.0))), null, DBusCallFlags.NONE, 3000, null);
                }
                if (request.has("Seek")) {
                    yield bus.call(n, PATH, PLAYER, "Seek", new Variant("(x)", request.get_int("Seek", 0)), null, DBusCallFlags.NONE, 3000, null);
                }
            } catch (Error e) {
                debug("nearby: media control: %s", e.message);
            }
        }
    }
}
