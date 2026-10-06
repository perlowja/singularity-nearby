namespace Singularity.Nearby {

    public errordomain PacketError {
        INVALID
    }

    public class Packet : Object {
        public const string IDENTITY = "kdeconnect.identity";
        public const string PAIR = "kdeconnect.pair";
        public const string PING = "kdeconnect.ping";
        public const string SHARE = "kdeconnect.share.request";
        public const string SHARE_UPDATE = "kdeconnect.share.request.update";
        public const string CLIPBOARD = "kdeconnect.clipboard";
        public const string CLIPBOARD_CONNECT = "kdeconnect.clipboard.connect";
        public const string NOTIFICATION = "kdeconnect.notification";
        public const string NOTIFICATION_REQUEST = "kdeconnect.notification.request";
        public const string NOTIFICATION_REPLY = "kdeconnect.notification.reply";
        public const string NOTIFICATION_ACTION = "kdeconnect.notification.action";
        public const string BATTERY = "kdeconnect.battery";
        public const string BATTERY_REQUEST = "kdeconnect.battery.request";
        public const string FINDMYPHONE = "kdeconnect.findmyphone.request";
        public const string SMS_MESSAGES = "kdeconnect.sms.messages";
        public const string SMS_REQUEST = "kdeconnect.sms.request";
        public const string SMS_CONVERSATIONS = "kdeconnect.sms.request_conversations";
        public const string SMS_CONVERSATION = "kdeconnect.sms.request_conversation";
        public const string MPRIS = "kdeconnect.mpris";
        public const string MPRIS_REQUEST = "kdeconnect.mpris.request";
        public const string RUNCOMMAND = "kdeconnect.runcommand";
        public const string RUNCOMMAND_REQUEST = "kdeconnect.runcommand.request";

        public const int PROTOCOL_VERSION = 8;
        public const size_t MAX_LINE = 1024 * 1024;

        public string packet_type { get; set; }
        public int64 id { get; set; }
        public Json.Object body { get; set; }
        public int64 payload_size { get; set; default = -1; }
        public int payload_port { get; set; default = 0; }

        public Packet(string packet_type, Json.Object? body = null) {
            Object(packet_type: packet_type);
            this.body = body ?? new Json.Object();
            id = get_real_time() / 1000;
        }

        public bool has_payload {
            get { return payload_size >= 0 && payload_port > 0; }
        }

        public string serialize() {
            var root = new Json.Object();
            root.set_int_member("id", get_real_time() / 1000);
            root.set_string_member("type", packet_type);
            root.set_object_member("body", body);
            if (payload_size >= 0) {
                root.set_int_member("payloadSize", payload_size);
                var info = new Json.Object();
                info.set_int_member("port", payload_port);
                root.set_object_member("payloadTransferInfo", info);
            }
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(root);
            var gen = new Json.Generator();
            gen.set_root(node);
            return gen.to_data(null) + "\n";
        }

        public static Packet parse(string line) throws PacketError {
            if (line.length > MAX_LINE) throw new PacketError.INVALID("packet too large");
            var parser = new Json.Parser();
            try {
                parser.load_from_data(line.strip(), -1);
            } catch (Error e) {
                throw new PacketError.INVALID("not JSON: %s", e.message);
            }
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) throw new PacketError.INVALID("not an object");
            var obj = root.get_object();
            var type_node = obj.get_member("type");
            if (type_node == null || type_node.get_value_type() != typeof(string)) throw new PacketError.INVALID("missing type");
            var body_node = obj.get_member("body");
            if (body_node != null && body_node.get_node_type() != Json.NodeType.OBJECT) throw new PacketError.INVALID("body is not an object");
            var packet = new Packet(type_node.get_string(), body_node != null ? body_node.get_object() : new Json.Object());
            var id_node = obj.get_member("id");
            if (id_node != null && id_node.get_node_type() == Json.NodeType.VALUE) packet.id = int_of(id_node, 0);
            var size_node = obj.get_member("payloadSize");
            if (size_node != null && size_node.get_node_type() == Json.NodeType.VALUE) packet.payload_size = int_of(size_node, -1);
            var info_node = obj.get_member("payloadTransferInfo");
            if (info_node != null && info_node.get_node_type() == Json.NodeType.OBJECT) {
                var port_node = info_node.get_object().get_member("port");
                if (port_node != null && port_node.get_node_type() == Json.NodeType.VALUE) packet.payload_port = (int) int_of(port_node, 0);
            }
            if (packet.payload_size >= 0 && packet.payload_port == 0) packet.payload_size = -1;
            return packet;
        }

        private static int64 int_of(Json.Node node, int64 fallback) {
            var t = node.get_value_type();
            if (t == typeof(int64)) return node.get_int();
            if (t == typeof(double)) return (int64) node.get_double();
            if (t == typeof(string)) {
                int64 v;
                if (int64.try_parse(node.get_string(), out v)) return v;
            }
            if (t == typeof(bool)) return node.get_boolean() ? 1 : 0;
            return fallback;
        }

        public bool has(string key) {
            return body.has_member(key) && body.get_member(key).get_node_type() != Json.NodeType.NULL;
        }

        public string? get_string(string key, string? fallback = null) {
            if (!body.has_member(key)) return fallback;
            var node = body.get_member(key);
            if (node.get_node_type() != Json.NodeType.VALUE) return fallback;
            var t = node.get_value_type();
            if (t == typeof(string)) return node.get_string();
            if (t == typeof(int64)) return node.get_int().to_string();
            if (t == typeof(bool)) return node.get_boolean() ? "true" : "false";
            if (t == typeof(double)) return node.get_double().to_string();
            return fallback;
        }

        public int64 get_int(string key, int64 fallback = 0) {
            if (!body.has_member(key)) return fallback;
            var node = body.get_member(key);
            if (node.get_node_type() != Json.NodeType.VALUE) return fallback;
            return int_of(node, fallback);
        }

        public bool get_bool(string key, bool fallback = false) {
            if (!body.has_member(key)) return fallback;
            var node = body.get_member(key);
            if (node.get_node_type() != Json.NodeType.VALUE) return fallback;
            var t = node.get_value_type();
            if (t == typeof(bool)) return node.get_boolean();
            if (t == typeof(int64)) return node.get_int() != 0;
            if (t == typeof(string)) return node.get_string() == "true";
            return fallback;
        }

        public string[] get_strv(string key) {
            string[] result = {};
            if (!body.has_member(key)) return result;
            var node = body.get_member(key);
            if (node.get_node_type() != Json.NodeType.ARRAY) return result;
            node.get_array().foreach_element((a, i, el) => {
                if (el.get_node_type() == Json.NodeType.VALUE && el.get_value_type() == typeof(string)) result += el.get_string();
            });
            return result;
        }

        public Json.Array? get_array(string key) {
            if (!body.has_member(key)) return null;
            var node = body.get_member(key);
            return node.get_node_type() == Json.NodeType.ARRAY ? node.get_array() : null;
        }

        public Packet set_string(string key, string value) {
            body.set_string_member(key, value);
            return this;
        }

        public Packet set_int(string key, int64 value) {
            body.set_int_member(key, value);
            return this;
        }

        public Packet set_bool(string key, bool value) {
            body.set_boolean_member(key, value);
            return this;
        }

        public Packet set_strv(string key, string[] values) {
            var arr = new Json.Array();
            foreach (string v in values) arr.add_string_element(v);
            body.set_array_member(key, arr);
            return this;
        }

        public static bool valid_device_id(string? id) {
            if (id == null || id.length < 32 || id.length > 38) return false;
            for (int i = 0; i < id.length; i++) {
                char c = id[i];
                if (!(c.isalnum() || c == '_' || c == '-')) return false;
            }
            return true;
        }

        public static string filter_name(string? name) {
            if (name == null) return "";
            var sb = new StringBuilder();
            unichar c;
            int i = 0;
            int count = 0;
            while (name.get_next_char(ref i, out c)) {
                if ("\"',;:.!?()[]<>".index_of_char(c) >= 0) continue;
                sb.append_unichar(c);
                if (++count >= 32) break;
            }
            return sb.str.strip();
        }

        public static string verification_code(Bytes local_key, Bytes peer_key, int64 timestamp) {
            unowned uint8[] a = local_key.get_data();
            unowned uint8[] b = peer_key.get_data();
            if (compare_bytes(a, b) < 0) {
                unowned uint8[] t = a;
                a = b;
                b = t;
            }
            var checksum = new Checksum(ChecksumType.SHA256);
            checksum.update(a, a.length);
            checksum.update(b, b.length);
            string ts = timestamp.to_string();
            checksum.update((uchar[]) ts.data, ts.length);
            return checksum.get_string().substring(0, 8).up();
        }

        private static int compare_bytes(uint8[] a, uint8[] b) {
            int n = int.min(a.length, b.length);
            for (int i = 0; i < n; i++) {
                if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
            }
            return a.length - b.length;
        }
    }
}
