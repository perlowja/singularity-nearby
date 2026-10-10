namespace Singularity.Nearby {

    [DBus (name = "dev.sinty.Collab1.Error")]
    public errordomain CollabError {
        DISABLED,
        NO_PERSON,
        NO_SESSION,
        INVALID
    }

    public class CollabPerson : Object {
        public string id;
        public string name;
        public string device_type;
        public string provider;
        public bool full;

        public HashTable<string, Variant> to_variant(string provider_name) {
            var d = new HashTable<string, Variant>(str_hash, str_equal);
            d["id"] = id;
            d["name"] = name;
            d["device-type"] = device_type;
            d["icon"] = Device.icon_for(device_type);
            d["provider"] = provider;
            d["provider-name"] = provider_name;
            d["sessions"] = full;
            return d;
        }
    }

    public abstract class CollabTransport : Object {
        public signal void received(string person, Json.Object message);
        public signal void changed();
        public signal void connected(string person);

        public abstract string id { get; }
        public abstract string display_name { owned get; }
        public abstract bool builtin { get; }
        public abstract Gee.List<CollabPerson> people();
        public abstract bool deliver(string person, Json.Object message);
        public virtual bool send_text(string person, string text) {
            return false;
        }
    }

    public class LanTransport : CollabTransport {
        public const string PACKET = "sinty.collab";
        public const int CHUNK = 512 * 1024;
        public const int MAX_PARTS = 2048;
        private unowned Service service;
        private Gee.HashMap<string, Gee.HashMap<int, string>> partial = new Gee.HashMap<string, Gee.HashMap<int, string>>();

        public LanTransport(Service service) {
            this.service = service;
        }

        public override string id { get { return "lan"; } }
        public override string display_name { owned get { return _("Local Network"); } }
        public override bool builtin { get { return true; } }

        public override Gee.List<CollabPerson> people() {
            var list = new Gee.ArrayList<CollabPerson>();
            foreach (var d in service.collab_devices()) {
                if (!d.paired || !d.reachable) continue;
                var p = new CollabPerson();
                p.id = d.id;
                p.name = d.name;
                p.device_type = d.device_type;
                p.provider = id;
                p.full = PACKET in d.incoming;
                list.add(p);
            }
            return list;
        }

        public override bool deliver(string person, Json.Object message) {
            var d = service.collab_device(person);
            if (d == null || !d.paired || !d.reachable || !(PACKET in d.incoming)) return false;
            string text = Collab.encode(message);
            if (text.length <= CHUNK) {
                service.collab_send(d, new Packet(PACKET).set_string("m", text));
                return true;
            }
            string id = Uuid.string_random();
            int n = (text.length + CHUNK - 1) / CHUNK;
            if (n > MAX_PARTS) return false;
            for (int i = 0; i < n; i++) {
                int start = i * CHUNK;
                int len = int.min(CHUNK, text.length - start);
                var p = new Packet(PACKET).set_string("c", id).set_int("i", i).set_int("n", n)
                    .set_string("part", Base64.encode(text.data[start:start + len]));
                service.collab_send(d, p);
            }
            return true;
        }

        public override bool send_text(string person, string text) {
            var d = service.collab_device(person);
            if (d == null || !d.paired || !d.reachable || !d.accepts(Packet.SHARE)) return false;
            service.collab_send(d, new Packet(Packet.SHARE).set_string("text", text));
            return true;
        }

        public void handle(Device d, Packet p) {
            string chunk = p.get_string("c", "");
            if (chunk != "") {
                int n = (int) p.get_int("n", 0);
                int i = (int) p.get_int("i", -1);
                if (n <= 0 || n > MAX_PARTS || i < 0 || i >= n) return;
                string key = d.id + "/" + chunk;
                var parts = partial[key];
                if (parts == null) {
                    if (partial.size > 64) partial.clear();
                    parts = new Gee.HashMap<int, string>();
                    partial[key] = parts;
                }
                parts[i] = p.get_string("part", "");
                if (parts.size < n) return;
                partial.unset(key);
                var buf = new ByteArray();
                for (int k = 0; k < n; k++) buf.append(Base64.decode(parts[k]));
                buf.append({ 0 });
                var whole = Collab.decode((string) buf.data);
                if (whole != null) received(d.id, whole);
                return;
            }
            var message = Collab.decode(p.get_string("m", ""));
            if (message != null) received(d.id, message);
        }
    }

    [DBus (name = "dev.sinty.CollabProvider1")]
    public interface CollabProviderBus : Object {
        public signal void people_changed();
        public signal void received(string person, string message);
        public abstract HashTable<string, Variant>[] list_people() throws DBusError, IOError;
        public abstract async void send(string person, string message) throws DBusError, IOError;
    }

    public class ExternalTransport : CollabTransport {
        private string _id;
        private string _name;
        private CollabProviderBus? proxy = null;
        private Gee.ArrayList<CollabPerson> cached = new Gee.ArrayList<CollabPerson>();

        public ExternalTransport(string id, string name, string bus_name, string object_path) {
            _id = id;
            _name = name;
            Bus.get_proxy.begin<CollabProviderBus>(BusType.SESSION, bus_name, object_path, DBusProxyFlags.NONE, null, (obj, res) => {
                try {
                    proxy = Bus.get_proxy.end(res);
                    proxy.people_changed.connect(refresh);
                    proxy.received.connect((person, message) => {
                        var m = Collab.decode(message);
                        if (m != null) received(person, m);
                    });
                    refresh();
                } catch (Error e) {
                    warning("collab: provider %s: %s", _id, e.message);
                }
            });
        }

        public override string id { get { return _id; } }
        public override string display_name { owned get { return _name; } }
        public override bool builtin { get { return false; } }

        private void refresh() {
            var list = new Gee.ArrayList<CollabPerson>();
            try {
                foreach (var entry in proxy.list_people()) {
                    var p = new CollabPerson();
                    p.id = entry.contains("id") ? entry["id"].get_string() : "";
                    p.name = entry.contains("name") ? entry["name"].get_string() : p.id;
                    p.device_type = entry.contains("device-type") ? entry["device-type"].get_string() : "computer";
                    p.provider = _id;
                    p.full = true;
                    if (p.id != "") list.add(p);
                }
            } catch (Error e) {
                debug("collab: provider %s: %s", _id, e.message);
            }
            var before = new Gee.HashSet<string>();
            foreach (var p in cached) before.add(p.id);
            cached = list;
            foreach (var p in list) if (!before.contains(p.id)) connected(p.id);
            changed();
        }

        public override Gee.List<CollabPerson> people() {
            return cached;
        }

        public override bool deliver(string person, Json.Object message) {
            if (proxy == null) return false;
            bool known = false;
            foreach (var p in cached) if (p.id == person) known = true;
            if (!known) return false;
            proxy.send.begin(person, Collab.encode(message), (obj, res) => {
                try {
                    proxy.send.end(res);
                } catch (Error e) {
                    warning("collab: provider %s: %s", _id, e.message);
                }
            });
            return true;
        }
    }

    public class CollabSession : Object {
        public string id;
        public string kind;
        public string title;
        public string role;
        public string host;
        public string host_name;
        public string app_bus = "";
        public Gee.HashMap<string, string> peers = new Gee.HashMap<string, string>();
        public Gee.ArrayList<string> pending = new Gee.ArrayList<string>();
        public Gee.ArrayList<string> log = new Gee.ArrayList<string>();
        public string snapshot = "";

        public bool hosting { get { return host == ""; } }

        public Json.Object to_json() {
            var o = new Json.Object();
            o.set_string_member("id", id);
            o.set_string_member("kind", kind);
            o.set_string_member("title", title);
            o.set_string_member("role", role);
            o.set_string_member("host", host);
            o.set_string_member("hostName", host_name);
            var p = new Json.Object();
            foreach (var e in peers.entries) p.set_string_member(e.key, e.value);
            o.set_object_member("peers", p);
            var waiting = new Json.Array();
            foreach (string person in pending) waiting.add_string_element(person);
            o.set_array_member("pending", waiting);
            return o;
        }

        public static CollabSession from_json(Json.Object o) {
            var s = new CollabSession();
            s.id = o.get_string_member_with_default("id", "");
            s.kind = o.get_string_member_with_default("kind", "");
            s.title = o.get_string_member_with_default("title", "");
            s.role = o.get_string_member_with_default("role", "edit");
            s.host = o.get_string_member_with_default("host", "");
            s.host_name = o.get_string_member_with_default("hostName", "");
            if (o.has_member("peers")) {
                var p = o.get_object_member("peers");
                foreach (string k in p.get_members()) s.peers[k] = p.get_string_member(k);
            }
            if (o.has_member("pending")) {
                o.get_array_member("pending").foreach_element((a, i, node) => s.pending.add(node.get_string()));
            }
            return s;
        }
    }

    [DBus (name = "dev.sinty.Collab1")]
    public class Collab : Object {
        public const string PROVIDER_INTERFACE = "dev.sinty.CollabProvider1";
        public const int MAX_LOG = 20000;
        public const int MAX_QUEUE = 5000;
        public const int MAX_HISTORY = 100;

        private unowned Service service;
        private string state_path;
        private Gee.ArrayList<CollabTransport> transports = new Gee.ArrayList<CollabTransport>();
        private Gee.HashMap<string, CollabSession> sessions = new Gee.HashMap<string, CollabSession>();
        private Gee.HashMap<string, Gee.ArrayList<string>> queue = new Gee.HashMap<string, Gee.ArrayList<string>>();
        private Gee.ArrayList<Json.Object> log_history = new Gee.ArrayList<Json.Object>();
        private Gee.HashMap<string, Json.Object> offers = new Gee.HashMap<string, Json.Object>();
        private bool _enabled = true;
        private uint save_id = 0;

        public signal void people_changed();
        public signal void sessions_changed();
        public signal void received(string session, string author, string data);
        public signal void joined(string session, string person, string name);
        public signal void left(string session, string person, string name);
        public signal void ended(string session);
        public signal void answered(string session, string name, bool accepted);
        public signal void offered(string offer, string name, string kind, string title, bool invite);
        public signal void offer_closed(string offer);

        [DBus (visible = false)]
        public LanTransport lan { get; private set; }

        public bool enabled {
            get { return _enabled; }
            set {
                if (_enabled == value) return;
                _enabled = value;
                schedule_save();
                service.collab_capabilities_changed();
                people_changed();
            }
        }

        [DBus (visible = false)]
        public Collab(Service service, string dir) {
            this.service = service;
            state_path = Path.build_filename(dir, "collab.json");
            lan = new LanTransport(service);
            add_transport(lan);
            load();
            load_providers();
            Timeout.add_seconds(5, () => {
                foreach (string person in queue.keys.to_array()) {
                    if (find_person(person) != null) flush(person);
                }
                return Source.CONTINUE;
            });
        }

        private void add_transport(CollabTransport t) {
            transports.add(t);
            t.changed.connect(() => people_changed());
            t.connected.connect((person) => flush(t.id + ":" + person));
            t.received.connect((person, m) => on_message(t.id + ":" + person, m));
        }

        [DBus (visible = false)]
        public static string encode(Json.Object o) {
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(o);
            return Json.to_string(node, false);
        }

        [DBus (visible = false)]
        public static Json.Object? decode(string text) {
            if (text == "") return null;
            try {
                var node = Json.from_string(text);
                return node != null && node.get_node_type() == Json.NodeType.OBJECT ? node.get_object() : null;
            } catch (Error e) {
                return null;
            }
        }

        [DBus (visible = false)]
        public static bool valid_kind(string kind) {
            if (kind.length == 0 || kind.length > 32) return false;
            for (int i = 0; i < kind.length; i++) {
                char c = kind[i];
                if (!c.isalpha()) return false;
            }
            return kind[0].isupper();
        }

        [DBus (visible = false)]
        public static string[] capability_dirs() {
            string[] dirs = { Path.build_filename(Environment.get_user_data_dir(), "singularity", "capabilities") };
            foreach (string d in Environment.get_system_data_dirs()) dirs += Path.build_filename(d, "singularity", "capabilities");
            return dirs;
        }

        private static KeyFile[] capability_files() {
            KeyFile[] files = {};
            var seen = new Gee.HashSet<string>();
            foreach (string dir in capability_dirs()) {
                Dir? handle = null;
                try {
                    handle = Dir.open(dir);
                } catch (Error e) {
                    continue;
                }
                string? name;
                while ((name = handle.read_name()) != null) {
                    if (!name.has_suffix(".ini") || seen.contains(name)) continue;
                    seen.add(name);
                    var kf = new KeyFile();
                    try {
                        kf.load_from_file(Path.build_filename(dir, name), KeyFileFlags.NONE);
                    } catch (Error e) {
                        continue;
                    }
                    files += kf;
                }
            }
            return files;
        }

        private static bool capability(string iface, out string bus_name, out string object_path) {
            bus_name = "";
            object_path = "";
            foreach (var kf in capability_files()) {
                try {
                    if (kf.get_string("Capability", "Interface") != iface) continue;
                    bus_name = kf.get_string("Capability", "BusName");
                    object_path = kf.get_string("Capability", "ObjectPath");
                    return bus_name != "" && object_path != "";
                } catch (Error e) {
                    continue;
                }
            }
            return false;
        }

        [DBus (visible = false)]
        public static string target_interface(string kind) {
            return "dev.sinty.Collab.%s1".printf(kind);
        }

        private void load_providers() {
            foreach (var kf in capability_files()) {
                try {
                    if (kf.get_string("Capability", "Interface") != PROVIDER_INTERFACE) continue;
                    string bus = kf.get_string("Capability", "BusName");
                    string path = kf.get_string("Capability", "ObjectPath");
                    string pid = kf.has_key("Capability", "ProviderId") ? kf.get_string("Capability", "ProviderId") : bus;
                    string pname = kf.has_key("Capability", "Name") ? kf.get_locale_string("Capability", "Name") : pid;
                    if (pid == "lan" || pid.contains(":")) continue;
                    add_transport(new ExternalTransport(pid, pname, bus, path));
                } catch (Error e) {
                    continue;
                }
            }
        }

        private CollabTransport? transport_for(string person, out string local) {
            local = "";
            int colon = person.index_of_char(':');
            if (colon <= 0) return null;
            string pid = person.substring(0, colon);
            local = person.substring(colon + 1);
            foreach (var t in transports) if (t.id == pid) return t;
            return null;
        }

        private CollabPerson? find_person(string person) {
            string local;
            var t = transport_for(person, out local);
            if (t == null) return null;
            foreach (var p in t.people()) if (p.id == local) return p;
            return null;
        }

        private string person_name(string person) {
            var p = find_person(person);
            if (p != null) return p.name;
            foreach (var s in sessions.values) if (s.peers.has_key(person)) return s.peers[person];
            return person;
        }

        private bool post_message(string person, Json.Object message, bool queue_when_offline) {
            string local;
            var t = transport_for(person, out local);
            if (t != null && t.deliver(local, message)) return true;
            debug("collab: %s is not reachable, %s", person, queue_when_offline ? "queued" : "dropped");
            if (!queue_when_offline) return false;
            var q = queue[person];
            if (q == null) {
                q = new Gee.ArrayList<string>();
                queue[person] = q;
            }
            q.add(encode(message));
            while (q.size > MAX_QUEUE) q.remove_at(0);
            schedule_save();
            return false;
        }

        [DBus (visible = false)]
        public void flush(string person) {
            var q = queue[person];
            if (q == null || q.size == 0) return;
            string local;
            var t = transport_for(person, out local);
            if (t == null) return;
            var rest = new Gee.ArrayList<string>();
            foreach (string text in q) {
                var m = decode(text);
                if (m == null) continue;
                if (rest.size > 0 || !t.deliver(local, m)) rest.add(text);
            }
            if (rest.size == 0) queue.unset(person);
            else queue[person] = rest;
            schedule_save();
        }

        [DBus (visible = false)]
        public void lan_connected(string device_id) {
            people_changed();
            flush("lan:" + device_id);
        }

        public HashTable<string, Variant>[] list_people() throws DBusError, IOError {
            HashTable<string, Variant>[] out = {};
            if (!_enabled) return out;
            foreach (var t in transports) {
                foreach (var p in t.people()) {
                    var v = p.to_variant(t.display_name);
                    v["id"] = t.id + ":" + p.id;
                    out += v;
                }
            }
            return out;
        }

        public HashTable<string, Variant>[] list_providers() throws DBusError, IOError {
            HashTable<string, Variant>[] out = {};
            foreach (var t in transports) {
                var d = new HashTable<string, Variant>(str_hash, str_equal);
                d["id"] = t.id;
                d["name"] = t.display_name;
                d["builtin"] = t.builtin;
                d["people"] = t.people().size;
                out += d;
            }
            return out;
        }

        public void send(string person, string kind, string title, string payload, string text) throws CollabError, DBusError, IOError {
            if (!_enabled) throw new CollabError.DISABLED("collaboration is turned off");
            if (!valid_kind(kind)) throw new CollabError.INVALID("invalid kind");
            var p = find_person(person);
            if (p == null) throw new CollabError.NO_PERSON("this person is not reachable");
            if (!p.full) {
                string local;
                var t = transport_for(person, out local);
                string body = text != "" ? text : title;
                if (title != "" && text != "" && !text.has_prefix(title)) body = title + "\n\n" + text;
                if (t == null || !t.send_text(local, body)) throw new CollabError.NO_PERSON("this person is not reachable");
                remember(false, person, kind, title, true);
                return;
            }
            var m = new Json.Object();
            m.set_string_member("t", "send");
            m.set_string_member("kind", kind);
            m.set_string_member("title", title);
            m.set_string_member("payload", payload);
            m.set_string_member("text", text);
            post_message(person, m, true);
            remember(false, person, kind, title, true);
        }

        public string share(string person, string kind, string title, string snapshot, string role, BusName sender) throws CollabError, DBusError, IOError {
            if (!_enabled) throw new CollabError.DISABLED("collaboration is turned off");
            if (!valid_kind(kind)) throw new CollabError.INVALID("invalid kind");
            var s = new CollabSession();
            s.id = Uuid.string_random();
            s.kind = kind;
            s.title = title;
            s.role = role == "view" ? "view" : "edit";
            s.host = "";
            s.host_name = service.name;
            s.snapshot = snapshot;
            s.app_bus = sender;
            sessions[s.id] = s;
            if (person != "") {
                try {
                    invite(s.id, person);
                } catch (CollabError e) {
                    sessions.unset(s.id);
                    throw e;
                }
            }
            schedule_save();
            sessions_changed();
            return s.id;
        }

        public void invite(string session, string person) throws CollabError, DBusError, IOError {
            var s = sessions[session];
            if (s == null || !s.hosting) throw new CollabError.NO_SESSION("no such session");
            var p = find_person(person);
            if (p != null && !p.full) throw new CollabError.NO_PERSON("this person cannot join a session");
            string local;
            if (p == null && transport_for(person, out local) == null) throw new CollabError.NO_PERSON("unknown person");
            var m = new Json.Object();
            m.set_string_member("t", "invite");
            m.set_string_member("session", s.id);
            m.set_string_member("kind", s.kind);
            m.set_string_member("title", s.title);
            m.set_string_member("role", s.role);
            m.set_string_member("host", service.name);
            if (!s.pending.contains(person)) s.pending.add(person);
            post_message(person, m, true);
            remember(false, person, s.kind, s.title, true);
        }

        public void update_snapshot(string session, string snapshot) throws CollabError, DBusError, IOError {
            var s = sessions[session];
            if (s == null || !s.hosting) throw new CollabError.NO_SESSION("no such session");
            s.snapshot = snapshot;
            s.log.clear();
        }

        public void post(string session, string data) throws CollabError, DBusError, IOError {
            var s = sessions[session];
            if (s == null) throw new CollabError.NO_SESSION("no such session");
            if (s.role == "view" && !s.hosting) throw new CollabError.INVALID("this session is read only");
            var m = new Json.Object();
            m.set_string_member("t", "op");
            m.set_string_member("session", s.id);
            m.set_string_member("data", data);
            m.set_string_member("by", service.name);
            if (s.hosting) {
                s.log.add(data);
                while (s.log.size > MAX_LOG) s.log.remove_at(0);
                foreach (string peer in s.peers.keys) post_message(peer, m, true);
            } else {
                post_message(s.host, m, true);
            }
        }

        public void leave(string session) throws CollabError, DBusError, IOError {
            var s = sessions[session];
            if (s == null) throw new CollabError.NO_SESSION("no such session");
            var m = new Json.Object();
            m.set_string_member("t", s.hosting ? "end" : "leave");
            m.set_string_member("session", s.id);
            if (s.hosting) {
                foreach (string peer in s.peers.keys) post_message(peer, m, true);
                foreach (string peer in s.pending) post_message(peer, m, false);
            } else {
                post_message(s.host, m, true);
            }
            sessions.unset(session);
            schedule_save();
            ended(session);
            sessions_changed();
        }

        public void remove_person(string session, string person) throws CollabError, DBusError, IOError {
            var s = sessions[session];
            if (s == null || !s.hosting) throw new CollabError.NO_SESSION("no such session");
            if (!s.peers.has_key(person)) return;
            string name = s.peers[person];
            s.peers.unset(person);
            var m = new Json.Object();
            m.set_string_member("t", "end");
            m.set_string_member("session", s.id);
            post_message(person, m, true);
            schedule_save();
            left(session, person, name);
            sessions_changed();
        }

        public HashTable<string, Variant>[] list_sessions() throws DBusError, IOError {
            HashTable<string, Variant>[] out = {};
            foreach (var s in sessions.values) {
                var d = new HashTable<string, Variant>(str_hash, str_equal);
                d["id"] = s.id;
                d["kind"] = s.kind;
                d["title"] = s.title;
                d["role"] = s.role;
                d["hosting"] = s.hosting;
                d["host-name"] = s.hosting ? service.name : s.host_name;
                string[] names = {};
                string[] ids = {};
                foreach (var e in s.peers.entries) {
                    ids += e.key;
                    names += e.value;
                }
                d["people"] = names;
                d["people-ids"] = ids;
                d["reachable"] = s.hosting || find_person(s.host) != null;
                out += d;
            }
            return out;
        }

        public HashTable<string, Variant>[] history() throws DBusError, IOError {
            HashTable<string, Variant>[] out = {};
            for (int i = log_history.size - 1; i >= 0; i--) {
                var o = log_history[i];
                var d = new HashTable<string, Variant>(str_hash, str_equal);
                d["time"] = o.get_int_member_with_default("time", 0);
                d["incoming"] = o.get_boolean_member_with_default("incoming", false);
                d["name"] = o.get_string_member_with_default("name", "");
                d["kind"] = o.get_string_member_with_default("kind", "");
                d["title"] = o.get_string_member_with_default("title", "");
                d["accepted"] = o.get_boolean_member_with_default("accepted", true);
                out += d;
            }
            return out;
        }

        public string get_snapshot(string session) throws CollabError, DBusError, IOError {
            var s = sessions[session];
            if (s == null) throw new CollabError.NO_SESSION("no such session");
            return s.snapshot;
        }

        public HashTable<string, Variant>[] list_offers() throws DBusError, IOError {
            HashTable<string, Variant>[] out = {};
            foreach (var e in offers.entries) {
                var d = new HashTable<string, Variant>(str_hash, str_equal);
                d["id"] = e.key;
                d["name"] = e.value.get_string_member_with_default("fromName", "");
                d["kind"] = e.value.get_string_member_with_default("kind", "");
                d["title"] = e.value.get_string_member_with_default("title", "");
                d["invite"] = e.value.get_string_member_with_default("t", "") == "invite";
                out += d;
            }
            return out;
        }

        public void accept(string offer) throws CollabError, DBusError, IOError {
            answer_offer(offer, true);
        }

        public void decline(string offer) throws CollabError, DBusError, IOError {
            answer_offer(offer, false);
        }

        private void remember(bool incoming, string person, string kind, string title, bool accepted) {
            var o = new Json.Object();
            o.set_int_member("time", get_real_time() / 1000000);
            o.set_boolean_member("incoming", incoming);
            o.set_string_member("name", person_name(person));
            o.set_string_member("kind", kind);
            o.set_string_member("title", title);
            o.set_boolean_member("accepted", accepted);
            log_history.add(o);
            while (log_history.size > MAX_HISTORY) log_history.remove_at(0);
            schedule_save();
        }

        private void on_message(string person, Json.Object m) {
            if (!_enabled) return;
            string t = m.get_string_member_with_default("t", "");
            string sid = m.get_string_member_with_default("session", "");
            switch (t) {
                case "send":
                case "invite":
                    offer(person, m);
                    break;
                case "answer":
                    on_answer(person, sid, m.get_boolean_member_with_default("accept", false));
                    break;
                case "welcome":
                    on_welcome(person, m);
                    break;
                case "op":
                    on_op(person, sid, m);
                    break;
                case "leave":
                    var s = sessions[sid];
                    if (s != null && s.hosting && s.peers.has_key(person)) {
                        string name = s.peers[person];
                        s.peers.unset(person);
                        schedule_save();
                        left(sid, person, name);
                        sessions_changed();
                    }
                    break;
                case "end":
                    var s = sessions[sid];
                    if (s != null && !s.hosting && s.host == person) {
                        sessions.unset(sid);
                        schedule_save();
                        ended(sid);
                        sessions_changed();
                        service.collab_notify(_("Collaboration Ended"), _("%s stopped sharing %s").printf(s.host_name, quoted(s.title)));
                    }
                    break;
                default:
                    break;
            }
        }

        private static string quoted(string title) {
            return "\"%s\"".printf(title);
        }

        private static string kind_label(string kind) {
            switch (kind) {
                case "Note": return _("a note");
                case "Task": return _("a task");
                case "TaskList": return _("a task list");
                case "Event": return _("an event");
                case "Color": return _("a color");
                case "Sheet": return _("a spreadsheet");
                case "Document": return _("a document");
                case "Presentation": return _("a presentation");
                case "Drawing": return _("a drawing");
                case "Database": return _("a database");
                case "Formula": return _("a formula");
                case "Publication": return _("a publication");
                default: return _("an item");
            }
        }

        private void offer(string person, Json.Object m) {
            string kind = m.get_string_member_with_default("kind", "");
            if (!valid_kind(kind)) return;
            string bus, path;
            string title = m.get_string_member_with_default("title", "");
            bool invite = m.get_string_member_with_default("t", "") == "invite";
            string name = person_name(person);
            if (!capability(target_interface(kind), out bus, out path)) {
                if (invite) reply_answer(person, m.get_string_member_with_default("session", ""), false);
                remember(true, person, kind, title, false);
                service.collab_notify(_("Could Not Receive"), _("%s sent you %s, but no installed app can open it.").printf(name, kind_label(kind)));
                return;
            }
            string id = Uuid.string_random();
            m.set_string_member("from", person);
            m.set_string_member("fromName", name);
            offers[id] = m;
            offered(id, name, kind, title, invite);
            string summary = invite
                ? _("%s Invites You to Work Together").printf(name)
                : _("%s Sent You %s").printf(name, kind_label(kind));
            string body = invite
                ? (m.get_string_member_with_default("role", "edit") == "view"
                    ? _("View %s as it changes").printf(quoted(title))
                    : _("Edit %s together").printf(quoted(title)))
                : quoted(title);
            service.collab_ask(summary, body, (action) => {
                try {
                    answer_offer(id, action == "accept");
                } catch (Error e) {
                    warning("collab: %s", e.message);
                }
            });
        }

        private void reply_answer(string person, string session, bool accepted) {
            var a = new Json.Object();
            a.set_string_member("t", "answer");
            a.set_string_member("session", session);
            a.set_boolean_member("accept", accepted);
            a.set_string_member("name", service.name);
            post_message(person, a, true);
        }

        private void answer_offer(string offer_id, bool accepted) throws CollabError {
            var m = offers[offer_id];
            if (m == null) throw new CollabError.INVALID("this request is no longer pending");
            offers.unset(offer_id);
            offer_closed(offer_id);
            string person = m.get_string_member_with_default("from", "");
            string kind = m.get_string_member_with_default("kind", "");
            string title = m.get_string_member_with_default("title", "");
            bool invite = m.get_string_member_with_default("t", "") == "invite";
            remember(true, person, kind, title, accepted);
            if (invite) {
                string sid = m.get_string_member_with_default("session", "");
                reply_answer(person, sid, accepted);
                if (!accepted) return;
                var s = new CollabSession();
                s.id = sid;
                s.kind = kind;
                s.title = title;
                s.role = m.get_string_member_with_default("role", "edit");
                s.host = person;
                s.host_name = person_name(person);
                sessions[sid] = s;
                schedule_save();
                sessions_changed();
                return;
            }
            if (!accepted) return;
            string bus, path;
            if (!capability(target_interface(kind), out bus, out path)) return;
            call_app(bus, path, target_interface(kind), "Receive",
                new Variant("(sss)", title, m.get_string_member_with_default("payload", ""), person_name(person)));
        }

        private void call_app(string bus, string path, string iface, string method, Variant args) {
            Bus.get.begin(BusType.SESSION, null, (obj, res) => {
                try {
                    var conn = Bus.get.end(res);
                    conn.call.begin(bus, path, iface, method, args, null, DBusCallFlags.NONE, 60000, null, (o, r) => {
                        try {
                            conn.call.end(r);
                        } catch (Error e) {
                            warning("collab: %s.%s: %s", iface, method, e.message);
                        }
                    });
                } catch (Error e) {
                    warning("collab: %s", e.message);
                }
            });
        }

        private void on_answer(string person, string sid, bool accepted) {
            var s = sessions[sid];
            if (s == null || !s.hosting) return;
            if (!s.pending.remove(person)) return;
            schedule_save();
            string name = person_name(person);
            answered(sid, name, accepted);
            if (!accepted) {
                service.collab_notify(_("Invitation Declined"), _("%s declined to join %s").printf(name, quoted(s.title)));
                return;
            }
            s.peers[person] = name;
            var w = new Json.Object();
            w.set_string_member("t", "welcome");
            w.set_string_member("session", sid);
            w.set_string_member("snapshot", s.snapshot);
            var ops = new Json.Array();
            foreach (string op in s.log) ops.add_string_element(op);
            w.set_array_member("ops", ops);
            var people = new Json.Object();
            people.set_string_member("", service.name);
            foreach (var e in s.peers.entries) if (e.key != person) people.set_string_member(e.key, e.value);
            w.set_object_member("people", people);
            post_message(person, w, true);
            schedule_save();
            joined(sid, person, name);
            sessions_changed();
        }

        private void on_welcome(string person, Json.Object m) {
            string sid = m.get_string_member_with_default("session", "");
            var s = sessions[sid];
            if (s == null || s.hosting || s.host != person) return;
            s.snapshot = m.get_string_member_with_default("snapshot", "");
            if (m.has_member("people")) {
                var people = m.get_object_member("people");
                foreach (string k in people.get_members()) {
                    if (k != "") s.peers[k] = people.get_string_member(k);
                }
            }
            string bus, path;
            if (!capability(target_interface(s.kind), out bus, out path)) return;
            call_app(bus, path, target_interface(s.kind), "Join",
                new Variant("(sssss)", sid, s.title, s.snapshot, s.role, s.host_name));
            if (m.has_member("ops")) {
                var ops = m.get_array_member("ops");
                uint n = ops.get_length();
                Timeout.add(1500, () => {
                    for (uint i = 0; i < n; i++) received(sid, s.host_name, ops.get_string_element(i));
                    return Source.REMOVE;
                });
            }
            sessions_changed();
        }

        private void on_op(string person, string sid, Json.Object op) {
            var s = sessions[sid];
            if (s == null) return;
            string data = op.get_string_member_with_default("data", "");
            string author;
            if (s.hosting) {
                if (!s.peers.has_key(person)) return;
                if (s.role == "view") return;
                author = s.peers[person];
                s.log.add(data);
                while (s.log.size > MAX_LOG) s.log.remove_at(0);
                var m = new Json.Object();
                m.set_string_member("t", "op");
                m.set_string_member("session", sid);
                m.set_string_member("data", data);
                m.set_string_member("by", author);
                foreach (string peer in s.peers.keys) if (peer != person) post_message(peer, m, true);
            } else {
                if (s.host != person) return;
                author = op.get_string_member_with_default("by", s.host_name);
            }
            received(sid, author, data);
        }

        private void load() {
            if (!FileUtils.test(state_path, FileTest.EXISTS)) return;
            try {
                string text;
                FileUtils.get_contents(state_path, out text);
                var root = decode(text);
                if (root == null) return;
                _enabled = root.get_boolean_member_with_default("enabled", true);
                if (root.has_member("sessions")) {
                    root.get_array_member("sessions").foreach_element((a, i, node) => {
                        if (node.get_node_type() != Json.NodeType.OBJECT) return;
                        var s = CollabSession.from_json(node.get_object());
                        if (s.id != "") sessions[s.id] = s;
                    });
                }
                if (root.has_member("queue")) {
                    var q = root.get_object_member("queue");
                    foreach (string person in q.get_members()) {
                        var list = new Gee.ArrayList<string>();
                        q.get_array_member(person).foreach_element((a, i, node) => list.add(node.get_string()));
                        queue[person] = list;
                    }
                }
                if (root.has_member("history")) {
                    root.get_array_member("history").foreach_element((a, i, node) => {
                        if (node.get_node_type() == Json.NodeType.OBJECT) log_history.add(node.get_object());
                    });
                }
            } catch (Error e) {
                warning("collab: cannot read %s: %s", state_path, e.message);
            }
        }

        private void schedule_save() {
            if (save_id != 0) return;
            save_id = Timeout.add(500, () => {
                save_id = 0;
                save_now();
                return Source.REMOVE;
            });
        }

        [DBus (visible = false)]
        public void save_now() {
            var root = new Json.Object();
            root.set_boolean_member("enabled", _enabled);
            var arr = new Json.Array();
            foreach (var s in sessions.values) arr.add_object_element(s.to_json());
            root.set_array_member("sessions", arr);
            var q = new Json.Object();
            foreach (var e in queue.entries) {
                var list = new Json.Array();
                foreach (string text in e.value) list.add_string_element(text);
                q.set_array_member(e.key, list);
            }
            root.set_object_member("queue", q);
            var h = new Json.Array();
            foreach (var o in log_history) h.add_object_element(o);
            root.set_array_member("history", h);
            try {
                FileUtils.set_contents(state_path, encode(root));
                FileUtils.chmod(state_path, 0600);
            } catch (Error e) {
                warning("collab: cannot save %s: %s", state_path, e.message);
            }
        }
    }
}
