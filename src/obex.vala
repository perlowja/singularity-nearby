namespace Singularity.Nearby {

    [DBus (name = "org.bluez.obex.Error")]
    public errordomain ObexError {
        REJECTED,
        CANCELED
    }

    public delegate void Answer(bool ok);
    public delegate void PushQuestion(string transfer, string device, string filename, int64 size, owned Answer answer);

    [DBus (name = "org.bluez.obex.Agent1")]
    public class ObexAgent : Object {
        private unowned Obex obex;

        public ObexAgent(Obex obex) {
            this.obex = obex;
        }

        public async string authorize_push(ObjectPath transfer) throws ObexError, DBusError, IOError {
            string? path = yield obex.authorize(transfer);
            if (path == null) throw new ObexError.REJECTED("Declined");
            return path;
        }

        public void cancel() throws DBusError, IOError {
            obex.cancel_question();
        }

        public void release() throws DBusError, IOError {
        }
    }

    public class Obex : Object {
        public const string NAME = "org.bluez.obex";
        public const string ROOT = "/org/bluez/obex";
        public const string AGENT_PATH = "/dev/sinty/Nearby/ObexAgent";
        public const string OPP_UUID = "00001105-0000-1000-8000-00805f9b34fb";

        public bool available { get; private set; default = false; }
        public string receive_folder { get; set; default = ""; }

        private DBusConnection bus;
        private ObexAgent agent;
        private uint agent_id = 0;
        private string? current_question = null;
        private Gee.HashMap<string, string> incoming = new Gee.HashMap<string, string>();

        public signal void progress(string id, int64 done, int64 total);
        public signal void finished(string id, bool ok, string message);
        public signal void received(string path, string device);
        public signal void cancelled(string transfer);

        public PushQuestion? question_handler;

        public Obex(DBusConnection bus) {
            this.bus = bus;
            agent = new ObexAgent(this);
            Bus.watch_name_on_connection(bus, NAME, BusNameWatcherFlags.NONE, () => {
                available = true;
                register.begin();
            }, () => {
                available = false;
            });
            bus.signal_subscribe(NAME, "org.freedesktop.DBus.Properties", "PropertiesChanged", null, "org.bluez.obex.Transfer1", DBusSignalFlags.MATCH_ARG0_NAMESPACE, on_transfer_changed);
        }

        private async void register() {
            try {
                if (agent_id == 0) agent_id = bus.register_object(AGENT_PATH, agent);
                yield bus.call(NAME, ROOT, "org.bluez.obex.AgentManager1", "RegisterAgent",
                    new Variant("(o)", AGENT_PATH), null, DBusCallFlags.NONE, 5000, null);
            } catch (Error e) {
                warning("nearby: cannot register the OBEX agent: %s", e.message);
            }
        }

        private async HashTable<string, Variant>? props(string path, string iface) {
            try {
                var reply = yield bus.call(NAME, path, "org.freedesktop.DBus.Properties", "GetAll",
                    new Variant("(s)", iface), new VariantType("(a{sv})"), DBusCallFlags.NONE, 5000, null);
                var table = new HashTable<string, Variant>(str_hash, str_equal);
                var iter = reply.get_child_value(0).iterator();
                string key;
                Variant val;
                while (iter.next("{sv}", out key, out val)) table[key] = val;
                return table;
            } catch (Error e) {
                return null;
            }
        }

        public async string? authorize(ObjectPath transfer) {
            var t = yield props(transfer, "org.bluez.obex.Transfer1");
            if (t == null) return null;
            string name = Files.safe_name(t.contains("Name") ? t["Name"].get_string() : "file");
            int64 size = t.contains("Size") ? (int64) t["Size"].get_uint64() : -1;
            string device = "";
            if (t.contains("Session")) {
                var s = yield props(t["Session"].get_string(), "org.bluez.obex.Session1");
                if (s != null && s.contains("Destination")) device = s["Destination"].get_string();
            }
            string label = device;
            foreach (var d in yield bluetooth_devices()) {
                if (d.contains("address") && d["address"].get_string().up() == device.up()) label = d["name"].get_string();
            }
            bool ok = false;
            if (question_handler != null) {
                bool answered = false;
                SourceFunc resume = authorize.callback;
                current_question = transfer;
                question_handler(transfer, label, name, size, (answer) => {
                    if (answered) return;
                    answered = true;
                    ok = answer;
                    Idle.add(() => {
                        resume();
                        return Source.REMOVE;
                    });
                });
                yield;
                current_question = null;
            }
            if (!ok) return null;
            string folder = receive_folder != "" ? receive_folder : UserConfig.default_receive_folder();
            DirUtils.create_with_parents(folder, 0755);
            string path = Files.unique_path(folder, name);
            incoming[transfer] = path + "\n" + label;
            return path;
        }

        public void cancel_question() {
            if (current_question != null) cancelled(current_question);
        }

        private void on_transfer_changed(DBusConnection c, string? sender, string path, string iface, string name, Variant parameters) {
            var changed = parameters.get_child_value(1);
            var status = changed.lookup_value("Status", VariantType.STRING);
            var transferred = changed.lookup_value("Transferred", VariantType.UINT64);
            if (transferred != null && outgoing_ids.has_key(path)) {
                progress(outgoing_ids[path], (int64) transferred.get_uint64(), outgoing_sizes[path]);
            }
            if (status == null) return;
            string s = status.get_string();
            if (incoming.has_key(path) && (s == "complete" || s == "error")) {
                string[] info = incoming[path].split("\n");
                incoming.unset(path);
                if (s == "complete") received(info[0], info.length > 1 ? info[1] : "");
                else FileUtils.remove(info[0]);
            }
            if (waiting.has_key(path) && (s == "complete" || s == "error")) {
                var cb = waiting[path];
                waiting.unset(path);
                statuses[path] = s;
                cb.callback();
            }
        }

        private class Waiter {
            public SourceFunc callback;
        }

        private Gee.HashMap<string, Waiter> waiting = new Gee.HashMap<string, Waiter>();
        private Gee.HashMap<string, string> statuses = new Gee.HashMap<string, string>();
        private Gee.HashMap<string, string> outgoing_ids = new Gee.HashMap<string, string>();
        private Gee.HashMap<string, int64?> outgoing_sizes = new Gee.HashMap<string, int64?>();

        public async void send_files(string id, string address, owned string[] uris) {
            string? session = null;
            try {
                if (!available) throw new IOError.NOT_SUPPORTED(_("Bluetooth file transfer is not available on this system"));
                var args = new VariantBuilder(new VariantType("a{sv}"));
                args.add("{sv}", "Target", new Variant.string("opp"));
                var reply = yield bus.call(NAME, ROOT, "org.bluez.obex.Client1", "CreateSession",
                    new Variant("(s@a{sv})", address, args.end()), new VariantType("(o)"), DBusCallFlags.NONE, 30000, null);
                session = reply.get_child_value(0).dup_string();
                foreach (string uri in uris) {
                    string? path = File.new_for_uri(uri).get_path();
                    if (path == null) throw new IOError.NOT_SUPPORTED(_("Only local files can be sent over Bluetooth"));
                    var sent = yield bus.call(NAME, session, "org.bluez.obex.ObjectPush1", "SendFile",
                        new Variant("(s)", path), new VariantType("(oa{sv})"), DBusCallFlags.NONE, 30000, null);
                    string transfer = sent.get_child_value(0).dup_string();
                    var p = sent.get_child_value(1);
                    var size = p.lookup_value("Size", VariantType.UINT64);
                    outgoing_ids[transfer] = id;
                    outgoing_sizes[transfer] = size != null ? (int64) size.get_uint64() : -1;
                    var st = p.lookup_value("Status", VariantType.STRING);
                    string status = st != null ? st.get_string() : "queued";
                    if (status != "complete" && status != "error") {
                        var w = new Waiter();
                        w.callback = send_files.callback;
                        waiting[transfer] = w;
                        uint guard = Timeout.add_seconds(600, () => {
                            if (waiting.has_key(transfer)) {
                                waiting.unset(transfer);
                                statuses[transfer] = "error";
                                send_files.callback();
                            }
                            return Source.REMOVE;
                        });
                        yield;
                        if (statuses[transfer] != "error") Source.remove(guard);
                        status = statuses[transfer] ?? "error";
                        statuses.unset(transfer);
                    }
                    outgoing_ids.unset(transfer);
                    outgoing_sizes.unset(transfer);
                    if (status != "complete") throw new IOError.FAILED(_("The other device did not accept %s").printf(Path.get_basename(path)));
                }
                finished(id, true, "");
            } catch (Error e) {
                finished(id, false, e.message);
            }
            if (session != null) {
                try {
                    yield bus.call(NAME, ROOT, "org.bluez.obex.Client1", "RemoveSession",
                        new Variant("(o)", session), null, DBusCallFlags.NONE, 5000, null);
                } catch (Error e) {
                }
            }
        }

        public static async HashTable<string, Variant>[] bluetooth_devices() {
            HashTable<string, Variant>[] result = {};
            try {
                var system = yield Bus.get(BusType.SYSTEM, null);
                var reply = yield system.call("org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects",
                    null, new VariantType("(a{oa{sa{sv}}})"), DBusCallFlags.NONE, 5000, null);
                var iter = reply.get_child_value(0).iterator();
                string path;
                Variant ifaces;
                while (iter.next("{o@a{sa{sv}}}", out path, out ifaces)) {
                    var dev = ifaces.lookup_value("org.bluez.Device1", null);
                    if (dev == null) continue;
                    var paired = dev.lookup_value("Paired", VariantType.BOOLEAN);
                    if (paired == null || !paired.get_boolean()) continue;
                    var uuids = dev.lookup_value("UUIDs", VariantType.STRING_ARRAY);
                    bool push = false;
                    if (uuids != null) foreach (string u in uuids.dup_strv()) if (u.down() == OPP_UUID) push = true;
                    if (!push) continue;
                    var d = new HashTable<string, Variant>(str_hash, str_equal);
                    var address = dev.lookup_value("Address", VariantType.STRING);
                    var alias = dev.lookup_value("Alias", VariantType.STRING) ?? dev.lookup_value("Name", VariantType.STRING);
                    var icon = dev.lookup_value("Icon", VariantType.STRING);
                    var connected = dev.lookup_value("Connected", VariantType.BOOLEAN);
                    if (address == null) continue;
                    d["address"] = address.get_string();
                    d["name"] = alias != null ? alias.get_string() : address.get_string();
                    d["icon"] = icon != null ? icon.get_string() + "-symbolic" : "bluetooth-symbolic";
                    d["connected"] = connected != null && connected.get_boolean();
                    result += d;
                }
            } catch (Error e) {
                debug("nearby: no Bluetooth devices: %s", e.message);
            }
            return result;
        }
    }
}
