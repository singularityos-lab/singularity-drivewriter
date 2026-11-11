namespace Singularity.Apps.DriveWriter {

    internal class DriveWriterIntents : Object {

        private static string text (Json.Object args, string key) {
            return args.has_member (key) ? args.get_string_member (key).strip () : "";
        }

        private static WriterWindow window (DriveWriterApp app) {
            var w = app.get_active_window () as WriterWindow;
            if (w == null) {
                foreach (var x in app.get_windows ()) {
                    w = x as WriterWindow;
                    if (w != null) break;
                }
            }
            if (w == null) {
                app.activate ();
                w = app.get_active_window () as WriterWindow;
            }
            return w;
        }

        private static async UDisksClient ready (WriterWindow w) throws Error {
            for (int i = 0; i < 100 && !w.agent_ready (); i++) {
                Timeout.add (100, ready.callback);
                yield;
            }
            var c = w.agent_client ();
            if (c == null) throw new IOError.NOT_CONNECTED ("the disk service of this computer could not be reached: %s", w.agent_client_error ());
            return c;
        }

        private static File resolve (string path) throws Error {
            if (path == "") throw new IOError.INVALID_ARGUMENT ("give the path of the image file");
            if (path.has_prefix ("file://")) return File.new_for_uri (path);
            if (path.has_prefix ("~/")) return File.new_for_path (Path.build_filename (Environment.get_home_dir (), path.substring (2)));
            if (!Path.is_absolute (path)) return File.new_for_path (Path.build_filename (Environment.get_home_dir (), path));
            return File.new_for_path (path);
        }

        private static TargetDrive find (UDisksClient c, string wanted) throws Error {
            if (wanted == "") throw new IOError.INVALID_ARGUMENT ("give the drive device or name from drivewriter_drives");
            var all = c.targets ();
            foreach (var d in all) if (d.device == wanted || d.id == wanted) return d;
            string w = wanted.casefold ();
            TargetDrive? hit = null;
            foreach (var d in all) {
                if (!d.title.casefold ().contains (w)) continue;
                if (hit != null) throw new IOError.INVALID_ARGUMENT ("%s matches more than one drive; use the device", wanted);
                hit = d;
            }
            if (hit != null) return hit;
            throw new IOError.NOT_FOUND ("no removable drive %s; Drive Writer only writes USB drives and memory cards, see drivewriter_drives", wanted);
        }

        private static Gee.List<TargetDrive> drives_from (UDisksClient c, Json.Object args) throws Error {
            var list = new Gee.ArrayList<TargetDrive> ();
            var seen = new Gee.HashSet<string> ();
            var wanted = new Gee.ArrayList<string> ();
            if (args.has_member ("drives")) {
                foreach (var n in args.get_array_member ("drives").get_elements ()) wanted.add (n.get_string ().strip ());
            }
            if (text (args, "drive") != "") wanted.add (text (args, "drive"));
            foreach (string w in wanted) {
                var d = find (c, w);
                if (seen.add (d.id)) list.add (d);
            }
            return list;
        }

        private static void drive_entry (Json.Builder b, TargetDrive d, ImageInfo? image) {
            b.begin_object ();
            b.set_member_name ("name").add_string_value (d.title);
            b.set_member_name ("device").add_string_value (d.device);
            b.set_member_name ("size").add_string_value (Format.size (d.size));
            if (image != null && image.problem == null) {
                var fit = image.fits (d.size);
                b.set_member_name ("image_fits").add_string_value (fit == Fit.FITS ? "yes" : (fit == Fit.TOO_LARGE ? "no, too small" : "only known while writing"));
            }
            b.end_object ();
        }

        private static void image_entry (Json.Builder b, WriterWindow w) {
            var image = w.agent_image ();
            b.begin_object ();
            b.set_member_name ("name").add_string_value (image.name);
            b.set_member_name ("path").add_string_value (image.file.get_path () ?? image.file.get_uri ());
            b.set_member_name ("kind").add_string_value (image.kind.describe ());
            b.set_member_name ("file_size").add_string_value (Format.size (image.file_size));
            if (image.kind.is_compressed ()) {
                b.set_member_name ("written_size").add_string_value (image.image_size >= 0 ? Format.size ((uint64) image.image_size) : "known only while writing");
            }
            if (image.problem != null) b.set_member_name ("problem").add_string_value (image.problem);
            var e = w.agent_expected ();
            if (e != null) {
                b.set_member_name ("checksum").add_string_value ("%s from %s".printf (e.algorithm (), e.source));
            }
            b.set_member_name ("checksum_state").add_string_value (w.agent_check_state ());
            b.end_object ();
        }

        private static async void drives (DriveWriterApp app, owned Singularity.AppIntentReply reply) {
            app.hold ();
            try {
                var w = window (app);
                var c = yield ready (w);
                var b = new Json.Builder ();
                b.begin_object ();
                b.set_member_name ("drives").begin_array ();
                foreach (var d in c.targets ()) drive_entry (b, d, w.agent_image ());
                b.end_array ();
                b.set_member_name ("note").add_string_value ("only USB drives and memory cards are listed; the system disk never is");
                b.end_object ();
                reply (b.get_root (), null);
            } catch (Error e) {
                reply (null, e);
            } finally {
                app.release ();
            }
        }

        private static async void choose (DriveWriterApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold ();
            try {
                var file = resolve (text (args, "file"));
                if (!file.query_exists ()) throw new IOError.NOT_FOUND ("%s does not exist", file.get_path () ?? file.get_uri ());
                var w = window (app);
                var c = yield ready (w);
                var before = w.agent_image ();
                w.agent_set_image (file);
                var image = w.agent_image ();
                if (image == null || !image.file.equal (file)) throw new IOError.FAILED ("the image was not opened");
                var b = new Json.Builder ();
                b.begin_object ();
                b.set_member_name ("image");
                image_entry (b, w);
                b.set_member_name ("drives").begin_array ();
                foreach (var d in c.targets ()) drive_entry (b, d, image);
                b.end_array ();
                b.set_member_name ("undo").add_string_value (before != null ? "drivewriter_image with file " + (before.file.get_path () ?? before.file.get_uri ()) : "nothing to undo, no drive was touched");
                b.end_object ();
                reply (b.get_root (), null);
            } catch (Error e) {
                reply (null, e);
            } finally {
                app.release ();
            }
        }

        private static async void check (DriveWriterApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold ();
            try {
                var w = window (app);
                yield ready (w);
                bool ok = yield w.agent_check (text (args, "checksum"));
                var b = new Json.Builder ();
                b.begin_object ();
                b.set_member_name ("image").add_string_value (w.agent_image ().name);
                b.set_member_name ("matches").add_boolean_value (ok);
                b.set_member_name ("state").add_string_value (w.agent_check_state ());
                b.end_object ();
                reply (b.get_root (), null);
            } catch (Error e) {
                reply (null, e);
            } finally {
                app.release ();
            }
        }

        private static Json.Node progress (WriterWindow w) {
            var b = new Json.Builder ();
            b.begin_object ();
            if (w.agent_image () != null) {
                b.set_member_name ("image");
                image_entry (b, w);
            }
            w.agent_progress (b);
            b.end_object ();
            return b.get_root ();
        }

        private static async void write (DriveWriterApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold ();
            try {
                var w = window (app);
                var c = yield ready (w);
                if (text (args, "file") != "") {
                    var file = resolve (text (args, "file"));
                    var current = w.agent_image ();
                    if (current == null || !current.file.equal (file)) w.agent_set_image (file);
                }
                var targets = drives_from (c, args);
                w.agent_write (targets);
                for (int i = 0; i < 20 && w.agent_busy (); i++) {
                    Timeout.add (100, write.callback);
                    yield;
                }
                var root = progress (w);
                var o = root.get_object ();
                o.set_boolean_member ("checks_after_writing", w.agent_verify_after ());
                o.set_string_member ("next", "writing takes minutes; follow it with drivewriter_status");
                reply (root, null);
            } catch (Error e) {
                reply (null, e);
            } finally {
                app.release ();
            }
        }

        private static async void stop (DriveWriterApp app, owned Singularity.AppIntentReply reply) {
            app.hold ();
            try {
                var w = window (app);
                w.agent_stop ();
                for (int i = 0; i < 100 && w.agent_busy (); i++) {
                    Timeout.add (100, stop.callback);
                    yield;
                }
                reply (progress (w), null);
            } catch (Error e) {
                reply (null, e);
            } finally {
                app.release ();
            }
        }

        private static async void restore (DriveWriterApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold ();
            try {
                var w = window (app);
                var c = yield ready (w);
                var target = find (c, text (args, "drive"));
                string fs = text (args, "filesystem").down ();
                if (fs != "" && fs != "fat32" && fs != "exfat") throw new IOError.INVALID_ARGUMENT ("filesystem is fat32 or exfat");
                var kind = fs == "exfat" ? FileSystemKind.EXFAT : FileSystemKind.FAT32;
                yield w.agent_restore (target, kind, text (args, "name"));
                var root = progress (w);
                bool ok = false;
                foreach (var d in c.targets ()) {
                    if (d.id != target.id) continue;
                    foreach (var p in c.blocks_of (d.drive)) {
                        if (p.has (IFACE_FILESYSTEM) && p.str (IFACE_BLOCK, "IdType") == kind.udisks_type ()) ok = true;
                    }
                }
                var o = root.get_object ();
                o.set_string_member ("drive", target.title);
                o.set_boolean_member ("restored", ok);
                if (!ok && o.has_member ("result")) throw new IOError.FAILED ("%s: %s", o.get_string_member ("result"), o.get_string_member ("message"));
                if (!ok) throw new IOError.FAILED ("%s does not show the new %s partition", target.title, kind.label ());
                reply (root, null);
            } catch (Error e) {
                reply (null, e);
            } finally {
                app.release ();
            }
        }

        private static async void eject (DriveWriterApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold ();
            try {
                var w = window (app);
                var c = yield ready (w);
                if (w.agent_busy ()) throw new IOError.BUSY ("a drive is being written or restored");
                var target = find (c, text (args, "drive"));
                bool done = yield c.eject (target);
                if (!done) throw new IOError.FAILED ("%s could not be ejected; close the files that use it and try again", target.title);
                var b = new Json.Builder ();
                b.begin_object ();
                b.set_member_name ("ejected").add_string_value (target.title);
                b.set_member_name ("still_connected").add_boolean_value (c.present (target));
                b.set_member_name ("undo").add_string_value ("unplug the drive and plug it in again");
                b.end_object ();
                reply (b.get_root (), null);
            } catch (Error e) {
                reply (null, e);
            } finally {
                app.release ();
            }
        }

        internal static void install (DriveWriterApp app) {
            var agent = app.agent;
            agent.add_async_intent ("drivewriter_drives", "The USB drives and memory cards Drive Writer can write, with their size and whether the chosen image fits.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args, reply) => {
                    drives.begin (app, (owned) reply);
                });
            agent.add_async_intent ("drivewriter_image", "Open a disk image (.iso, .img, .raw or xz, gzip, zstd compressed) in Drive Writer. Shows its type, size, any checksum found next to it and which drives it fits. Nothing is written.",
                "{\"type\":\"object\",\"properties\":{\"file\":{\"type\":\"string\",\"description\":\"path of the image, ~ for the home folder\"}},\"required\":[\"file\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    choose.begin (app, args, (owned) reply);
                });
            agent.add_async_intent ("drivewriter_check", "Check the open image against its SHA-256 or SHA-512 checksum. Give the value or the lines of a SHA256SUMS file from the download page, or leave it out to use the checksum found next to the image.",
                "{\"type\":\"object\",\"properties\":{\"checksum\":{\"type\":\"string\"}}}", Singularity.AppIntentRisk.READ, (args, reply) => {
                    check.begin (app, args, (owned) reply);
                });
            agent.add_async_intent ("drivewriter_write", "Erase one or more USB drives or memory cards and write the image to them. Everything on those drives is lost. The drive is checked after writing when the setting is on, then ejected.",
                "{\"type\":\"object\",\"properties\":{\"file\":{\"type\":\"string\",\"description\":\"image to write; the open one when left out\"},\"drive\":{\"type\":\"string\"},\"drives\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}",
                Singularity.AppIntentRisk.IRREVERSIBLE, (args, reply) => {
                    write.begin (app, args, (owned) reply);
                });
            agent.add_intent ("drivewriter_status", "What Drive Writer is doing: the open image, writing or checking progress per drive, and the result.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args) => {
                    return progress (window (app));
                });
            agent.add_async_intent ("drivewriter_stop", "Stop writing. Drives that were being written are left partly written and do not work until they are written again or restored.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.IRREVERSIBLE, (args, reply) => {
                    stop.begin (app, (owned) reply);
                });
            agent.add_async_intent ("drivewriter_restore", "Erase a USB drive or memory card that holds an image and give it one FAT32 or exFAT partition for files again. Everything on it is lost.",
                "{\"type\":\"object\",\"properties\":{\"drive\":{\"type\":\"string\"},\"filesystem\":{\"type\":\"string\",\"enum\":[\"fat32\",\"exfat\"]},\"name\":{\"type\":\"string\"}},\"required\":[\"drive\"]}",
                Singularity.AppIntentRisk.IRREVERSIBLE, (args, reply) => {
                    restore.begin (app, args, (owned) reply);
                });
            agent.add_async_intent ("drivewriter_eject", "Safely remove a USB drive or memory card: unmount it and power it off.",
                "{\"type\":\"object\",\"properties\":{\"drive\":{\"type\":\"string\"}},\"required\":[\"drive\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    eject.begin (app, args, (owned) reply);
                });
        }
    }
}
