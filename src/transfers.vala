namespace Singularity.Nearby {

    public class IncomingFile : Object {
        public string id { get; construct; }
        public string filename { get; construct; }
        public int64 size { get; construct; }
        public string staging { get; construct; }
        public bool complete { get; set; default = false; }
        public bool failed { get; set; default = false; }
        public bool open_after { get; set; default = false; }
        public string final_path { get; set; default = ""; }
        public Cancellable cancellable { get; default = new Cancellable(); }

        public IncomingFile(string id, string filename, int64 size, string staging) {
            Object(id: id, filename: filename, size: size, staging: staging);
        }
    }

    public enum Decision {
        UNDECIDED,
        ACCEPTED,
        DECLINED
    }

    public class IncomingBatch : Object {
        public string id { get; construct; }
        public string device_id { get; construct; }
        public Decision decision { get; set; default = Decision.UNDECIDED; }
        public uint32 notification { get; set; default = 0; }
        public uint timeout { get; set; default = 0; }
        public Gee.ArrayList<IncomingFile> files { get; default = new Gee.ArrayList<IncomingFile>(); }

        public IncomingBatch(string id, string device_id) {
            Object(id: id, device_id: device_id);
        }

        public int64 total_size {
            get {
                int64 t = 0;
                foreach (var f in files) t += int64.max(0, f.size);
                return t;
            }
        }
    }

    public class Files : Object {
        public static string staging_dir() {
            string dir = Path.build_filename(Environment.get_user_cache_dir(), "singularity", "nearby", "incoming");
            DirUtils.create_with_parents(dir, 0700);
            return dir;
        }

        public static string icon_dir() {
            string dir = Path.build_filename(Environment.get_user_cache_dir(), "singularity", "nearby", "icons");
            DirUtils.create_with_parents(dir, 0700);
            return dir;
        }

        public static string safe_name(string? name) {
            string n = Path.get_basename(name ?? "");
            n = n.replace("/", "_").replace("\\", "_").replace("\n", " ").replace("\r", " ").strip();
            while (n.has_prefix(".")) n = n.substring(1);
            if (n == "" || n == "." || n == "..") n = "file";
            if (n.length > 200) n = n.substring(n.length - 200);
            return n;
        }

        public static string unique_path(string folder, string name) {
            string path = Path.build_filename(folder, name);
            if (!FileUtils.test(path, FileTest.EXISTS)) return path;
            string stem = name;
            string ext = "";
            int dot = name.last_index_of_char('.');
            if (dot > 0) {
                stem = name.substring(0, dot);
                ext = name.substring(dot);
            }
            for (int i = 1; i < 10000; i++) {
                path = Path.build_filename(folder, "%s (%d)%s".printf(stem, i, ext));
                if (!FileUtils.test(path, FileTest.EXISTS)) return path;
            }
            return Path.build_filename(folder, "%s %s%s".printf(stem, Uuid.string_random(), ext));
        }
    }
}
