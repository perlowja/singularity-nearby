namespace Singularity.Nearby {

    public class ReceivedFile : Object {
        public string path { get; set; default = ""; }
        public string device_id { get; set; default = ""; }
        public string device_name { get; set; default = ""; }
        public int64 time { get; set; default = 0; }
        public int64 size { get; set; default = 0; }

        public HashTable<string, Variant> to_dict() {
            var d = new HashTable<string, Variant>(str_hash, str_equal);
            d["path"] = path;
            d["name"] = Path.get_basename(path);
            d["device-id"] = device_id;
            d["device-name"] = device_name;
            d["time"] = time;
            d["size"] = size;
            d["exists"] = FileUtils.test(path, FileTest.IS_REGULAR);
            return d;
        }
    }

    public class ReceivedHistory : Object {
        public const int LIMIT = 200;

        public string file { get; construct; }
        public Gee.ArrayList<ReceivedFile> entries { get; default = new Gee.ArrayList<ReceivedFile>(); }

        public signal void changed();

        public ReceivedHistory(string file) {
            Object(file: file);
        }

        public static string default_file() {
            return Path.build_filename(Environment.get_user_data_dir(), "singularity", "nearby", "received.json");
        }

        public void load() {
            entries.clear();
            if (!FileUtils.test(file, FileTest.EXISTS)) return;
            string data;
            try {
                if (!FileUtils.get_contents(file, out data)) return;
                var parser = new Json.Parser();
                parser.load_from_data(data);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return;
                root.get_array().foreach_element((a, i, node) => {
                    if (node.get_node_type() != Json.NodeType.OBJECT) return;
                    var o = node.get_object();
                    var e = new ReceivedFile();
                    e.path = o.get_string_member_with_default("path", "");
                    e.device_id = o.get_string_member_with_default("device-id", "");
                    e.device_name = o.get_string_member_with_default("device-name", "");
                    e.time = o.get_int_member_with_default("time", 0);
                    e.size = o.get_int_member_with_default("size", 0);
                    if (e.path != "" && entries.size < LIMIT) entries.add(e);
                });
            } catch (Error e) {
                warning("nearby: cannot read %s: %s", file, e.message);
            }
        }

        private void save() {
            var builder = new Json.Builder();
            builder.begin_array();
            foreach (var e in entries) {
                builder.begin_object();
                builder.set_member_name("path").add_string_value(e.path);
                builder.set_member_name("device-id").add_string_value(e.device_id);
                builder.set_member_name("device-name").add_string_value(e.device_name);
                builder.set_member_name("time").add_int_value(e.time);
                builder.set_member_name("size").add_int_value(e.size);
                builder.end_object();
            }
            builder.end_array();
            var gen = new Json.Generator();
            gen.root = builder.get_root();
            try {
                DirUtils.create_with_parents(Path.get_dirname(file), 0700);
                FileUtils.set_contents_full(file, gen.to_data(null), -1, FileSetContentsFlags.CONSISTENT, 0600);
            } catch (Error e) {
                warning("nearby: cannot write %s: %s", file, e.message);
            }
        }

        public void add(string path, string device_id, string device_name) {
            var e = new ReceivedFile();
            e.path = path;
            e.device_id = device_id;
            e.device_name = device_name;
            e.time = get_real_time() / 1000000;
            try {
                e.size = File.new_for_path(path).query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE).get_size();
            } catch (Error err) {
            }
            entries.insert(0, e);
            while (entries.size > LIMIT) entries.remove_at(entries.size - 1);
            save();
            changed();
        }

        public void forget(string path) {
            bool removed = false;
            foreach (var e in entries.to_array()) {
                if (e.path == path) {
                    entries.remove(e);
                    removed = true;
                }
            }
            if (!removed) return;
            save();
            changed();
        }

        public void clear() {
            if (entries.size == 0) return;
            entries.clear();
            save();
            changed();
        }
    }

    public class TransferInfo : Object {
        public string id { get; construct; }
        public string device_id { get; set; default = ""; }
        public string batch { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public bool incoming { get; set; default = false; }
        public int64 done { get; set; default = 0; }
        public int64 total { get; set; default = 0; }
        public string state { get; set; default = "running"; }
        public string detail { get; set; default = ""; }

        public TransferInfo(string id) {
            Object(id: id);
        }

        public HashTable<string, Variant> to_dict() {
            var d = new HashTable<string, Variant>(str_hash, str_equal);
            d["id"] = id;
            d["device-id"] = device_id;
            d["batch"] = batch;
            d["name"] = name;
            d["incoming"] = incoming;
            d["done"] = done;
            d["total"] = total;
            d["state"] = state;
            d["detail"] = detail;
            return d;
        }
    }
}
