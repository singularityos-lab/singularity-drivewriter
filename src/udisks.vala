namespace Singularity.Apps.DriveWriter {

    public const string UDISKS = "org.freedesktop.UDisks2";
    public const string IFACE_DRIVE = "org.freedesktop.UDisks2.Drive";
    public const string IFACE_BLOCK = "org.freedesktop.UDisks2.Block";
    public const string IFACE_PARTITION = "org.freedesktop.UDisks2.Partition";
    public const string IFACE_FILESYSTEM = "org.freedesktop.UDisks2.Filesystem";
    public const string IFACE_ENCRYPTED = "org.freedesktop.UDisks2.Encrypted";
    public const string IFACE_SWAP = "org.freedesktop.UDisks2.Swapspace";
    public const string IFACE_PARTITION_TABLE = "org.freedesktop.UDisks2.PartitionTable";
    public const string IFACE_MANAGER = "org.freedesktop.UDisks2.Manager";
    public const string MANAGER_PATH = "/org/freedesktop/UDisks2/Manager";

    public enum FileSystemKind {
        FAT32,
        EXFAT;

        public string udisks_type () {
            return this == EXFAT ? "exfat" : "vfat";
        }

        public string mbr_type () {
            return this == EXFAT ? "0x07" : "0x0c";
        }

        public int label_limit () {
            return this == EXFAT ? 15 : 11;
        }

        public string label () {
            return this == EXFAT ? "exFAT" : "FAT32";
        }

        public string? check_label (string text) {
            if (text.char_count () > label_limit ()) return ngettext ("Use at most %d character.", "Use at most %d characters.", label_limit ()).printf (label_limit ());
            unichar c;
            int i = 0;
            while (text.get_next_char (ref i, out c)) {
                if (c < 0x20 || c == 0x7f) return _("The name has characters that are not allowed.");
                if (this == FAT32 && (c > 0x7e || "\"*+,./:;<=>?[\\]|".index_of_char (c) >= 0)) return _("FAT32 names can use only letters A to Z, digits, spaces and a few symbols.");
                if (this == EXFAT && "\"*/:<>?\\|".index_of_char (c) >= 0) return _("The name has characters that are not allowed.");
            }
            return null;
        }

        public string normalize_label (string text) {
            string t = text.strip ();
            return this == FAT32 ? t.up () : t;
        }
    }

    public class UObject : Object {
        public DBusObject object;
        public string path;

        public UObject (DBusObject object) {
            this.object = object;
            this.path = object.get_object_path ();
        }

        public DBusProxy? iface (string name) {
            return object.get_interface (name) as DBusProxy;
        }

        public bool has (string name) {
            return object.get_interface (name) != null;
        }

        public Variant? prop (string iface_name, string property) {
            var proxy = iface (iface_name);
            return proxy != null ? proxy.get_cached_property (property) : null;
        }

        public string str (string iface_name, string property) {
            var v = prop (iface_name, property);
            if (v == null) return "";
            if (v.is_of_type (VariantType.STRING) || v.is_of_type (VariantType.OBJECT_PATH)) return v.get_string ();
            if (v.is_of_type (VariantType.BYTESTRING)) return bytestring (v);
            return "";
        }

        public uint64 u64 (string iface_name, string property) {
            var v = prop (iface_name, property);
            if (v == null) return 0;
            if (v.is_of_type (VariantType.UINT64)) return v.get_uint64 ();
            if (v.is_of_type (VariantType.INT64)) return (uint64) v.get_int64 ();
            if (v.is_of_type (VariantType.UINT32)) return v.get_uint32 ();
            return 0;
        }

        public bool flag (string iface_name, string property) {
            var v = prop (iface_name, property);
            return v != null && v.is_of_type (VariantType.BOOLEAN) && v.get_boolean ();
        }

        public static string bytestring (Variant v) {
            if (v.is_of_type (VariantType.BYTESTRING)) return v.get_bytestring ();
            var builder = new StringBuilder ();
            for (size_t i = 0; i < v.n_children (); i++) {
                uint8 c = v.get_child_value (i).get_byte ();
                if (c == 0) break;
                builder.append_c ((char) c);
            }
            return builder.str;
        }

        public string[] mount_points () {
            string[] result = {};
            var v = prop (IFACE_FILESYSTEM, "MountPoints");
            if (v == null) return result;
            for (size_t i = 0; i < v.n_children (); i++) result += bytestring (v.get_child_value (i));
            return result;
        }

        public string device () {
            string preferred = str (IFACE_BLOCK, "PreferredDevice");
            return preferred != "" ? preferred : str (IFACE_BLOCK, "Device");
        }

        public async Variant call (string iface_name, string method, Variant? parameters, int timeout = -1) throws Error {
            var proxy = iface (iface_name);
            if (proxy == null) throw new IOError.NOT_SUPPORTED ("%s is not available", iface_name);
            return yield proxy.call (method, parameters, DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, timeout, null);
        }
    }

    public static Variant empty_options () {
        return new Variant.array (new VariantType ("{sv}"), {});
    }

    public struct DriveTraits {
        public bool removable;
        public bool media_removable;
        public string bus;
        public bool optical;
        public uint64 size;
        public bool hint_ignore;
        public bool holds_system;
    }

    public class DriveFilter : Object {
        private const string[] SYSTEM_MOUNTS = { "/", "/boot", "/boot/efi", "/efi", "/usr", "/var", "/home", "/sysroot", "/run/rootfsbase" };

        public static bool accept (DriveTraits t) {
            if (t.size == 0 || t.optical || t.hint_ignore || t.holds_system) return false;
            return t.removable || t.media_removable || t.bus == "usb" || t.bus == "sdio" || t.bus == "ieee1394";
        }

        public static bool is_system_mount (string mount_point) {
            string m = mount_point.has_suffix ("/") && mount_point.length > 1 ? mount_point.substring (0, mount_point.length - 1) : mount_point;
            foreach (string s in SYSTEM_MOUNTS) if (m == s) return true;
            return false;
        }
    }

    public class TargetDrive : Object {
        public UObject drive;
        public UObject block;
        public string title;
        public string device;
        public uint64 size;

        public string id {
            get { return drive.path; }
        }
    }

    public class UDisksClient : Object {
        private DBusObjectManagerClient manager;
        private Gee.HashMap<string, UObject> objects = new Gee.HashMap<string, UObject> ();
        private uint changed_source = 0;

        public signal void changed ();

        public static async UDisksClient create () throws Error {
            var client = new UDisksClient ();
            client.manager = yield new DBusObjectManagerClient.for_bus (BusType.SYSTEM,
                DBusObjectManagerClientFlags.NONE, UDISKS, "/org/freedesktop/UDisks2", null, null);
            client.manager.object_added.connect (() => client.queue_changed ());
            client.manager.object_removed.connect (() => client.queue_changed ());
            client.manager.interface_added.connect (() => client.queue_changed ());
            client.manager.interface_removed.connect (() => client.queue_changed ());
            client.manager.interface_proxy_properties_changed.connect (() => client.queue_changed ());
            return client;
        }

        public bool available {
            get { return manager != null && manager.name_owner != null; }
        }

        private void queue_changed () {
            if (changed_source != 0) return;
            changed_source = Timeout.add (150, () => {
                changed_source = 0;
                changed ();
                return Source.REMOVE;
            });
        }

        public UObject? lookup (string? path) {
            if (path == null || path == "" || path == "/") return null;
            var existing = objects[path];
            var dbus_object = manager.get_object (path);
            if (dbus_object == null) {
                objects.unset (path);
                return null;
            }
            if (existing != null && existing.object == dbus_object) return existing;
            var wrapped = new UObject (dbus_object);
            objects[path] = wrapped;
            return wrapped;
        }

        public Gee.List<UObject> all () {
            var list = new Gee.ArrayList<UObject> ();
            foreach (var o in manager.get_objects ()) {
                var wrapped = lookup (o.get_object_path ());
                if (wrapped != null) list.add (wrapped);
            }
            return list;
        }

        public Gee.List<UObject> blocks_of (UObject drive) {
            var direct = new Gee.ArrayList<UObject> ();
            var everything = all ();
            foreach (var o in everything) {
                if (o.has (IFACE_BLOCK) && o.str (IFACE_BLOCK, "Drive") == drive.path) direct.add (o);
            }
            var result = new Gee.ArrayList<UObject> ();
            result.add_all (direct);
            foreach (var o in everything) {
                if (!o.has (IFACE_BLOCK)) continue;
                string backing = o.str (IFACE_BLOCK, "CryptoBackingDevice");
                foreach (var d in direct) {
                    if (backing == d.path) {
                        result.add (o);
                        break;
                    }
                }
            }
            return result;
        }

        public UObject? whole_block (UObject drive) {
            foreach (var o in blocks_of (drive)) {
                if (o.has (IFACE_PARTITION)) continue;
                if (o.str (IFACE_BLOCK, "Drive") != drive.path) continue;
                return o;
            }
            return null;
        }

        public DriveTraits traits (UObject drive) {
            DriveTraits t = DriveTraits ();
            t.removable = drive.flag (IFACE_DRIVE, "Removable");
            t.media_removable = drive.flag (IFACE_DRIVE, "MediaRemovable");
            t.bus = drive.str (IFACE_DRIVE, "ConnectionBus");
            t.optical = drive.flag (IFACE_DRIVE, "Optical");
            t.size = drive.u64 (IFACE_DRIVE, "Size");
            t.hint_ignore = false;
            t.holds_system = false;
            foreach (var b in blocks_of (drive)) {
                if (b.flag (IFACE_BLOCK, "HintIgnore") && !b.has (IFACE_PARTITION)) t.hint_ignore = true;
                if (b.has (IFACE_SWAP) && b.flag (IFACE_SWAP, "Active")) t.holds_system = true;
                if (!b.has (IFACE_FILESYSTEM)) continue;
                foreach (string m in b.mount_points ()) {
                    if (DriveFilter.is_system_mount (m)) t.holds_system = true;
                }
            }
            return t;
        }

        public Gee.List<TargetDrive> targets () {
            var list = new Gee.ArrayList<TargetDrive> ();
            foreach (var o in all ()) {
                if (!o.has (IFACE_DRIVE)) continue;
                if (!DriveFilter.accept (traits (o))) continue;
                var block = whole_block (o);
                if (block == null) continue;
                var t = new TargetDrive ();
                t.drive = o;
                t.block = block;
                t.size = block.u64 (IFACE_BLOCK, "Size");
                if (t.size == 0) t.size = o.u64 (IFACE_DRIVE, "Size");
                t.device = block.device ();
                string vendor = o.str (IFACE_DRIVE, "Vendor").strip ();
                string model = o.str (IFACE_DRIVE, "Model").strip ();
                if (model == "") t.title = vendor;
                else if (vendor == "" || model.has_prefix (vendor)) t.title = model;
                else t.title = "%s %s".printf (vendor, model);
                if (t.title == "") t.title = _("Removable Drive");
                list.add (t);
            }
            list.sort ((a, b) => strcmp (a.device, b.device));
            return list;
        }

        public async void release (TargetDrive target) throws Error {
            var blocks = blocks_of (target.drive);
            foreach (var b in blocks) {
                if (b.str (IFACE_BLOCK, "CryptoBackingDevice") == "/" || b.str (IFACE_BLOCK, "CryptoBackingDevice") == "") continue;
                yield unmount (b);
            }
            foreach (var b in blocks) yield unmount (b);
            foreach (var b in blocks) {
                if (b.has (IFACE_SWAP) && b.flag (IFACE_SWAP, "Active")) yield b.call (IFACE_SWAP, "Stop", new Variant ("(@a{sv})", empty_options ()));
                if (!b.has (IFACE_ENCRYPTED)) continue;
                foreach (var o in all ()) {
                    if (o.has (IFACE_BLOCK) && o.str (IFACE_BLOCK, "CryptoBackingDevice") == b.path) {
                        yield b.call (IFACE_ENCRYPTED, "Lock", new Variant ("(@a{sv})", empty_options ()));
                        break;
                    }
                }
            }
        }

        private async void unmount (UObject b) throws Error {
            if (!b.has (IFACE_FILESYSTEM) || b.mount_points ().length == 0) return;
            yield b.call (IFACE_FILESYSTEM, "Unmount", new Variant ("(@a{sv})", empty_options ()));
        }

        public async int open_for (TargetDrive target, string method) throws Error {
            var proxy = target.block.iface (IFACE_BLOCK);
            if (proxy == null) throw new IOError.NOT_FOUND (_("The drive is no longer connected."));
            UnixFDList? fds;
            var reply = yield proxy.call_with_unix_fd_list (method, new Variant ("(@a{sv})", empty_options ()),
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, -1, null, null, out fds);
            int32 index;
            reply.get ("(h)", out index);
            if (fds == null) throw new IOError.FAILED (_("No file descriptor was returned"));
            return fds.get (index);
        }

        public async bool eject (TargetDrive target) {
            try {
                yield release (target);
            } catch (Error e) {
                return false;
            }
            bool done = false;
            if (target.drive.flag (IFACE_DRIVE, "Ejectable")) {
                try {
                    yield target.drive.call (IFACE_DRIVE, "Eject", new Variant ("(@a{sv})", empty_options ()));
                    done = true;
                } catch (Error e) {
                }
            }
            if (target.drive.flag (IFACE_DRIVE, "CanPowerOff") && lookup (target.drive.path) != null) {
                try {
                    yield target.drive.call (IFACE_DRIVE, "PowerOff", new Variant ("(@a{sv})", empty_options ()));
                    done = true;
                } catch (Error e) {
                }
            }
            return done;
        }

        public async bool can_format (FileSystemKind kind) {
            var manager_object = lookup (MANAGER_PATH);
            if (manager_object == null) return false;
            try {
                var reply = yield manager_object.call (IFACE_MANAGER, "CanFormat", new Variant ("(s)", kind.udisks_type ()));
                bool available;
                string util;
                reply.get ("((bs))", out available, out util);
                return available;
            } catch (Error e) {
                return false;
            }
        }

        private async UObject wait_for (string path, string iface_name) throws Error {
            for (int i = 0; i < 100; i++) {
                var o = lookup (path);
                if (o != null && o.has (iface_name)) return o;
                Timeout.add (100, wait_for.callback);
                yield;
            }
            throw new IOError.TIMED_OUT (_("The drive did not get ready in time."));
        }

        public async void restore (TargetDrive target, FileSystemKind kind, string label) throws Error {
            yield release (target);
            yield target.block.call (IFACE_BLOCK, "Format", new Variant ("(s@a{sv})", "dos", empty_options ()), 600000);
            var block = yield wait_for (target.block.path, IFACE_PARTITION_TABLE);
            var format_options = new VariantBuilder (new VariantType ("a{sv}"));
            string name = kind.normalize_label (label);
            if (name != "") format_options.add ("{sv}", "label", new Variant.string (name));
            format_options.add ("{sv}", "update-partition-type", new Variant.boolean (true));
            yield block.call (IFACE_PARTITION_TABLE, "CreatePartitionAndFormat",
                new Variant ("(ttss@a{sv}s@a{sv})", (uint64) 1048576, (uint64) 0, kind.mbr_type (), "", empty_options (), kind.udisks_type (), format_options.end ()),
                600000);
        }

        public bool present (TargetDrive target) {
            return lookup (target.drive.path) != null && lookup (target.block.path) != null;
        }
    }
}
