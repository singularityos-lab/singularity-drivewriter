namespace Singularity.Apps.DriveWriter {

    public errordomain ChecksumError {
        INVALID,
        NOT_LISTED,
        MISMATCH
    }

    public class ExpectedHash : Object {
        public ChecksumType kind { get; construct; }
        public string hex { get; construct; }
        public string source { get; construct; }

        public ExpectedHash (ChecksumType kind, string hex, string source) {
            Object (kind: kind, hex: hex, source: source);
        }

        public string algorithm () {
            return kind == ChecksumType.SHA512 ? "SHA-512" : "SHA-256";
        }

        public bool matches (string actual) {
            return actual.down () == hex;
        }
    }

    public class ChecksumList : Object {
        private const int MAX_TEXT = 4 * 1024 * 1024;
        private Gee.HashMap<string, string> entries = new Gee.HashMap<string, string> ();
        private string? bare;

        public int size {
            get { return entries.size + (bare != null ? 1 : 0); }
        }

        public static bool is_hex (string text) {
            if (text.length != 64 && text.length != 128) return false;
            for (int i = 0; i < text.length; i++) if (!text[i].isxdigit ()) return false;
            return true;
        }

        public static ChecksumType kind_for (string hex) {
            return hex.length == 128 ? ChecksumType.SHA512 : ChecksumType.SHA256;
        }

        public static string? clean_hash (string text) {
            string t = text.strip ();
            int colon = t.index_of_char (':');
            if (colon > 0) {
                string prefix = t.substring (0, colon).down ().replace ("-", "");
                if (prefix == "sha256" || prefix == "sha512") t = t.substring (colon + 1).strip ();
            }
            t = t.down ();
            return is_hex (t) ? t : null;
        }

        private static string base_name (string path) {
            string p = path.strip ();
            if (p.has_prefix ("./")) p = p.substring (2);
            int slash = int.max (p.last_index_of_char ('/'), p.last_index_of_char ('\\'));
            return slash >= 0 ? p.substring (slash + 1) : p;
        }

        private void add (string hash, string name) {
            string key = base_name (name);
            if (key == "") return;
            if (!entries.has_key (key)) entries[key] = hash;
        }

        public static ChecksumList parse (string text) throws ChecksumError {
            if (text.length > MAX_TEXT) throw new ChecksumError.INVALID (_("The checksum file is too large."));
            var list = new ChecksumList ();
            foreach (string raw in text.split ("\n")) {
                string line = raw.strip ();
                if (line == "" || line.has_prefix ("#")) continue;
                if (line.has_prefix ("SHA256 (") || line.has_prefix ("SHA512 (")) {
                    int close = line.last_index_of (") = ");
                    if (close < 0) continue;
                    string name = line.substring (8, close - 8);
                    string hash = line.substring (close + 4).strip ().down ();
                    if (is_hex (hash)) list.add (hash, name);
                    continue;
                }
                int space = -1;
                for (int i = 0; i < line.length; i++) {
                    if (line[i] == ' ' || line[i] == '\t') {
                        space = i;
                        break;
                    }
                }
                if (space < 0) {
                    string? only = clean_hash (line);
                    if (only != null && list.bare == null) list.bare = only;
                    continue;
                }
                string hash = line.substring (0, space).down ();
                if (!is_hex (hash)) continue;
                string name = line.substring (space).strip ();
                if (name.has_prefix ("*")) name = name.substring (1);
                if (name == "") {
                    if (list.bare == null) list.bare = hash;
                    continue;
                }
                list.add (hash, name);
            }
            if (list.size == 0) throw new ChecksumError.INVALID (_("No SHA-256 checksums were found."));
            return list;
        }

        public string? lookup (string image_name) {
            string key = base_name (image_name);
            if (entries.has_key (key)) return entries[key];
            foreach (var e in entries.entries) {
                if (e.key.down () == key.down ()) return e.value;
            }
            if (bare != null && entries.size == 0) return bare;
            return null;
        }

        public ExpectedHash expected_for (string image_name, string source) throws ChecksumError {
            string? hash = lookup (image_name);
            if (hash == null) throw new ChecksumError.NOT_LISTED (_("%s does not list %s.").printf (source, image_name));
            return new ExpectedHash (kind_for (hash), hash, source);
        }
    }

    public class Sidecar : Object {
        private const int64 MAX_SIZE = 4 * 1024 * 1024;

        public static string[] candidates (string image_name) {
            return {
                image_name + ".sha256",
                image_name + ".sha256sum",
                image_name + ".sha256.txt",
                image_name + ".sha512",
                "SHA256SUMS",
                "SHA256SUMS.txt",
                "sha256sums.txt",
                "sha256sum.txt",
                "SHA512SUMS",
                "CHECKSUM"
            };
        }

        private static bool looks_like_list (string name) {
            string n = name.down ();
            return n.has_suffix ("checksum") || n.has_suffix ("checksums") || n.has_suffix ("sha256sums") || n.has_suffix ("sha256sums.txt") || n.has_suffix (".sha256");
        }

        private static ExpectedHash? try_file (File file, string image_name) {
            try {
                var info = file.query_info (FileAttribute.STANDARD_SIZE + "," + FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NONE);
                if (info.get_file_type () != FileType.REGULAR || info.get_size () > MAX_SIZE) return null;
                uint8[] data;
                file.load_contents (null, out data, null);
                string text = (string) data;
                if (!text.validate ()) return null;
                var list = ChecksumList.parse (text);
                return list.expected_for (image_name, file.get_basename ());
            } catch (Error e) {
                return null;
            }
        }

        public static ExpectedHash? find (File image) {
            var dir = image.get_parent ();
            string? name = image.get_basename ();
            if (dir == null || name == null) return null;
            foreach (string c in candidates (name)) {
                var found = try_file (dir.get_child (c), name);
                if (found != null) return found;
            }
            try {
                var e = dir.enumerate_children (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE);
                FileInfo? info;
                int seen = 0;
                while ((info = e.next_file ()) != null && seen < 2000) {
                    seen++;
                    string n = info.get_name ();
                    if (n == name || !looks_like_list (n)) continue;
                    var found = try_file (dir.get_child (n), name);
                    if (found != null) return found;
                }
            } catch (Error e) {
            }
            return null;
        }
    }

    public class HashJob : Object {
        private Mutex mutex = Mutex ();
        private uint64 done;
        public Cancellable cancellable { get; private set; default = new Cancellable (); }
        public uint64 total { get; private set; }

        public uint64 progress () {
            mutex.lock ();
            uint64 v = done;
            mutex.unlock ();
            return v;
        }

        public static string hash_stream (InputStream stream, ChecksumType kind, Cancellable? cancel, Tick? tick) throws Error {
            var checksum = new Checksum (kind);
            var buffer = new uint8[Copier.BUFFER];
            uint64 count = 0;
            while (true) {
                if (cancel != null) cancel.set_error_if_cancelled ();
                ssize_t got = stream.read (buffer, cancel);
                if (got <= 0) break;
                checksum.update (buffer, (size_t) got);
                count += got;
                if (tick != null) tick (count);
            }
            return checksum.get_string ();
        }

        public async string run (File file, ChecksumType kind) throws Error {
            var info = yield file.query_info_async (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE, Priority.DEFAULT, cancellable);
            total = info.get_size ();
            Error? failure = null;
            string result = "";
            SourceFunc callback = run.callback;
            new Thread<bool> ("drivewriter-hash", () => {
                try {
                    var stream = file.read (cancellable);
                    result = hash_stream (stream, kind, cancellable, (n) => {
                        mutex.lock ();
                        done = n;
                        mutex.unlock ();
                    });
                    stream.close ();
                } catch (Error e) {
                    failure = e;
                }
                Idle.add ((owned) callback);
                return true;
            });
            yield;
            if (failure != null) throw failure;
            return result;
        }
    }
}
