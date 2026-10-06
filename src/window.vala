using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.DriveWriter {

    public class WriterSettings : Object {
        public bool verify { get; set; default = true; }
        public bool parallel { get; set; default = true; }

        private GLib.Settings gsettings;

        private static string legacy_path () {
            return Path.build_filename (Environment.get_user_config_dir (), "singularity", "drivewriter.ini");
        }

        public void load () {
            gsettings = new GLib.Settings ("dev.sinty.drivewriter");
            migrate ();
            gsettings.bind ("verify-after-write", this, "verify", SettingsBindFlags.DEFAULT);
            gsettings.bind ("write-at-once", this, "parallel", SettingsBindFlags.DEFAULT);
        }

        private void migrate () {
            var kf = new KeyFile ();
            try {
                kf.load_from_file (legacy_path (), KeyFileFlags.NONE);
            } catch (Error e) {
                return;
            }
            try {
                gsettings.set_boolean ("verify-after-write", kf.get_boolean ("writer", "verify"));
            } catch (Error e) {
            }
            try {
                gsettings.set_boolean ("write-at-once", kf.get_boolean ("writer", "parallel"));
            } catch (Error e) {
            }
            GLib.Settings.sync ();
            FileUtils.unlink (legacy_path ());
        }
    }

    public enum CheckState {
        NONE,
        READY,
        CHECKING,
        MATCH,
        MISMATCH,
        FAILED
    }

    public class DriveTask : Object {
        public TargetDrive target;
        public WriteJob? job;
        public bool finished;
        public bool ok;
        public bool removed;
        public bool verified;
        public bool ejected;
        public Phase phase = Phase.WRITING;
        public double fraction;
        public string failure_title = "";
        public string failure = "";
        public ActionRow? row;
        public CircularProgress? ring;

        public DriveTask (TargetDrive target) {
            this.target = target;
        }

        public double overall (bool with_verify) {
            if (finished) return 1;
            if (!with_verify) return phase == Phase.WRITING ? fraction : 1;
            return phase == Phase.WRITING ? fraction / 2 : 0.5 + fraction / 2;
        }
    }

    public class WriterWindow : Singularity.Widgets.Window {
        private DriveWriterApp app;
        private WriterSettings settings = new WriterSettings ();
        private UDisksClient? client;
        private string client_error = "";
        private bool client_loading = true;
        private ImageInfo? image;
        private Gee.HashSet<string> chosen = new Gee.HashSet<string> ();
        private Gee.List<TargetDrive> drives = new Gee.ArrayList<TargetDrive> ();
        private Gee.ArrayList<DriveTask> tasks = new Gee.ArrayList<DriveTask> ();
        private HashJob? hash_job;
        private bool busy;
        private bool restoring;
        private bool close_after;
        private uint inhibit_cookie;
        private string return_page = "welcome";

        private ExpectedHash? expected;
        private CheckState check_state = CheckState.NONE;
        private string check_error = "";
        private bool expected_from_paste;

        private Stack stack;
        private Image image_icon;
        private Label image_name;
        private Label image_detail;
        private Label image_problem;
        private Stack drive_stack;
        private PreferencesGroup drive_group;
        private StatusPage no_drives;
        private Gee.ArrayList<Widget> drive_rows = new Gee.ArrayList<Widget> ();
        private Gee.HashMap<string, CheckButton> checks = new Gee.HashMap<string, CheckButton> ();
        private Label fit_label;
        private ActionRow check_row;
        private CircularProgress check_ring;
        private Button check_button;
        private Button check_clear;
        private Button check_stop;
        private EntryRow paste_row;
        private SelectionRow mode_row;
        private CircularProgress ring;
        private Label phase_label;
        private Label target_label;
        private Label detail_label;
        private PreferencesGroup task_group;
        private Gee.ArrayList<Widget> task_rows = new Gee.ArrayList<Widget> ();
        private StatusPage result_page;
        private PreferencesGroup result_group;
        private Gee.ArrayList<Widget> result_rows = new Gee.ArrayList<Widget> ();
        private Button again_button;
        private Button retry_button;
        private Button write_bubble;
        private Button open_bubble;
        private Button cancel_bubble;
        private Button back_bubble;
        private Button restore_bubble;

        private Stack restore_stack;
        private PreferencesGroup restore_group;
        private StatusPage restore_none;
        private Gee.ArrayList<Widget> restore_rows = new Gee.ArrayList<Widget> ();
        private string? restore_id;
        private SelectionRow fs_row;
        private EntryRow label_row;
        private bool exfat_available = true;

        public WriterWindow (DriveWriterApp app) {
            Object (application: app);
            this.app = app;
            settings.load ();
            set_default_size (760, 680);
            set_title (_("Drive Writer"));

            stack = new Stack ();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.add_named (build_welcome (), "welcome");
            stack.add_named (build_setup (), "setup");
            stack.add_named (build_restore (), "restore");
            stack.add_named (build_progress (), "progress");
            stack.add_named (build_result (), "result");
            set_content (stack);

            back_bubble = add_bubble_icon ("go-previous-symbolic", _("Back"), () => leave_restore ());
            open_bubble = add_bubble_icon ("document-open-symbolic", _("Choose Image (Ctrl+O)"), () => choose_image ());
            cancel_bubble = add_bubble_text (_("Cancel"), () => confirm_cancel ());
            write_bubble = add_bubble_suggested (_("Write"), () => confirm_write ());
            restore_bubble = add_bubble_suggested (_("Restore"), () => confirm_restore ());

            var drop = new DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
            drop.drop.connect ((value, x, y) => {
                if (busy) return false;
                var list = (Gdk.FileList) value.get_boxed ();
                foreach (var file in list.get_files ()) {
                    if (image != null && is_checksum_name (file.get_basename () ?? "")) load_checksum_file (file);
                    else set_image (file);
                    return true;
                }
                return false;
            });
            ((Widget) this).add_controller (drop);

            install_actions ();
            ring.notify["fraction"].connect (() => update_launcher ());
            close_request.connect (() => {
                if (!busy) return false;
                close_after = true;
                confirm_cancel ();
                return true;
            });
            sync ();
            connect_udisks.begin ();
        }

        private Widget build_welcome () {
            var wp = new WelcomePage ();
            wp.app_icon_name = "dev.sinty.drivewriter";
            wp.title = _("Drive Writer");
            wp.subtitle = _("Write a disk image to a USB drive or memory card, ready to start a computer from it");
            wp.add_action ("media-optical", _("Choose Image"), _("An .iso, .img or compressed image, or drop it here"), () => choose_image ());
            wp.add_action ("drive-removable-media", _("Restore a Drive"), _("Erase a drive that holds an image and make it usable for files again"), () => show_restore ());
            return wp;
        }

        private Widget build_setup () {
            var box = new Box (Orientation.VERTICAL, 18);
            box.margin_top = 24;
            box.margin_bottom = 32;
            box.margin_start = 24;
            box.margin_end = 24;

            var head = new Box (Orientation.HORIZONTAL, 16);
            image_icon = new Image ();
            image_icon.pixel_size = 64;
            image_icon.valign = Align.CENTER;
            head.append (image_icon);
            var texts = new Box (Orientation.VERTICAL, 4);
            texts.valign = Align.CENTER;
            texts.hexpand = true;
            image_name = new Label ("");
            image_name.xalign = 0;
            image_name.wrap = true;
            image_name.wrap_mode = Pango.WrapMode.WORD_CHAR;
            image_name.add_css_class ("title-2");
            texts.append (image_name);
            image_detail = new Label ("");
            image_detail.xalign = 0;
            image_detail.wrap = true;
            image_detail.add_css_class ("dim-label");
            texts.append (image_detail);
            head.append (texts);
            box.append (head);

            image_problem = new Label ("");
            image_problem.xalign = 0;
            image_problem.wrap = true;
            image_problem.add_css_class ("error");
            image_problem.visible = false;
            box.append (image_problem);

            drive_stack = new Stack ();
            drive_stack.vhomogeneous = false;
            drive_group = new PreferencesGroup (_("Drives"), _("Choose one or more drives. Everything on them will be erased."));
            drive_stack.add_named (drive_group, "list");
            no_drives = new StatusPage ();
            no_drives.icon_name = "drive-removable-media-symbolic";
            drive_stack.add_named (no_drives, "none");
            box.append (drive_stack);

            fit_label = new Label ("");
            fit_label.xalign = 0;
            fit_label.wrap = true;
            fit_label.add_css_class ("dim-label");
            fit_label.add_css_class ("caption");
            fit_label.visible = false;
            box.append (fit_label);

            var check_group = new PreferencesGroup (_("Checksum"), _("Compare the image with the checksum published next to it before writing."));
            check_row = new ActionRow (_("No Checksum"), null, "dialog-question-symbolic");
            check_row.activatable = false;
            check_ring = new CircularProgress (28);
            check_ring.visible = false;
            check_row.add_suffix (check_ring);
            check_stop = new Button.from_icon_name ("process-stop-symbolic");
            check_stop.add_css_class ("flat");
            check_stop.tooltip_text = _("Stop Checking");
            check_stop.valign = Align.CENTER;
            check_stop.clicked.connect (() => {
                if (hash_job != null && !busy) hash_job.cancellable.cancel ();
            });
            check_row.add_suffix (check_stop);
            check_button = new Button.with_label (_("Check Now"));
            check_button.add_css_class ("pill");
            check_button.valign = Align.CENTER;
            check_button.clicked.connect (() => check_now.begin ());
            check_row.add_suffix (check_button);
            check_clear = new Button.from_icon_name ("edit-clear-symbolic");
            check_clear.add_css_class ("flat");
            check_clear.tooltip_text = _("Forget This Checksum");
            check_clear.valign = Align.CENTER;
            check_clear.clicked.connect (() => {
                paste_row.text = "";
                set_expected (null, false);
            });
            check_row.add_suffix (check_clear);
            check_group.add_row (check_row);
            paste_row = new EntryRow (_("Paste a Checksum"));
            paste_row.subtitle = _("The SHA-256 value from the download page, or the lines of a SHA256SUMS file");
            paste_row.entry_changed.connect (() => on_paste ());
            check_group.add_row (paste_row);
            var file_row = new ActionRow (_("Choose a Checksum File…"), _("A SHA256SUMS, CHECKSUM or .sha256 file"), "document-open-symbolic");
            file_row.activated.connect (() => choose_checksum ());
            check_group.add_row (file_row);
            box.append (check_group);

            var options = new PreferencesGroup ();
            var verify = new SwitchRow (_("Check the Drive After Writing"), _("Reads everything back and compares it with the image"), settings.verify);
            verify.switch_btn.notify["active"].connect (() => {
                settings.verify = verify.active;
            });
            settings.notify["verify"].connect (() => verify.active = settings.verify);
            options.add_row (verify);
            string parallel_label = _("At Once");
            string sequential_label = _("One by One");
            mode_row = new SelectionRow (_("Several Drives"), { parallel_label, sequential_label },
                settings.parallel ? parallel_label : sequential_label);
            mode_row.selected.connect ((item) => {
                settings.parallel = item == parallel_label;
                sync_mode_row ();
            });
            settings.notify["parallel"].connect (() => {
                mode_row.current_value = settings.parallel ? parallel_label : sequential_label;
                sync_mode_row ();
            });
            options.add_row (mode_row);
            box.append (options);
            sync_mode_row ();
            update_check_row ();

            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = new Clamp (box) { maximum = 600 };
            apply_view_edge (scroll);
            return scroll;
        }

        private Widget build_restore () {
            var box = new Box (Orientation.VERTICAL, 18);
            box.margin_top = 24;
            box.margin_bottom = 32;
            box.margin_start = 24;
            box.margin_end = 24;

            var head = new Box (Orientation.HORIZONTAL, 16);
            var icon = new Image.from_icon_name ("drive-removable-media");
            icon.pixel_size = 64;
            icon.valign = Align.CENTER;
            head.append (icon);
            var texts = new Box (Orientation.VERTICAL, 4);
            texts.valign = Align.CENTER;
            texts.hexpand = true;
            var title = new Label (_("Restore a Drive"));
            title.xalign = 0;
            title.add_css_class ("title-2");
            texts.append (title);
            var about = new Label (_("After an image is written, a drive can no longer hold files. Restoring erases it and gives it one empty partition."));
            about.xalign = 0;
            about.wrap = true;
            about.add_css_class ("dim-label");
            texts.append (about);
            head.append (texts);
            box.append (head);

            restore_stack = new Stack ();
            restore_stack.vhomogeneous = false;
            restore_group = new PreferencesGroup (_("Drive"), _("Everything on the chosen drive will be erased."));
            restore_stack.add_named (restore_group, "list");
            restore_none = new StatusPage ();
            restore_none.icon_name = "drive-removable-media-symbolic";
            restore_stack.add_named (restore_none, "none");
            box.append (restore_stack);

            var format_group = new PreferencesGroup (_("New Format"));
            fs_row = new SelectionRow (_("Format"), { "FAT32", "exFAT" }, "FAT32");
            fs_row.selected.connect (() => sync_restore ());
            format_group.add_row (fs_row);
            label_row = new EntryRow (_("Name"));
            label_row.text = "USB DRIVE";
            label_row.entry_changed.connect (() => sync_restore ());
            label_row.entry_activated.connect (() => {
                if (restore_bubble.sensitive) confirm_restore ();
            });
            format_group.add_row (label_row);
            box.append (format_group);


            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = new Clamp (box) { maximum = 600 };
            apply_view_edge (scroll);
            return scroll;
        }

        private Widget build_progress () {
            var box = new Box (Orientation.VERTICAL, 14);
            box.valign = Align.CENTER;
            box.halign = Align.CENTER;
            box.margin_start = 24;
            box.margin_end = 24;
            box.margin_top = 24;
            box.margin_bottom = 24;
            ring = new CircularProgress (168);
            ring.add_css_class ("drivewriter-ring");
            ring.margin_bottom = 12;
            ring.halign = Align.CENTER;
            box.append (ring);
            phase_label = new Label ("");
            phase_label.add_css_class ("title-2");
            box.append (phase_label);
            target_label = new Label ("");
            target_label.wrap = true;
            target_label.justify = Justification.CENTER;
            target_label.max_width_chars = 48;
            box.append (target_label);
            detail_label = new Label ("");
            detail_label.add_css_class ("dim-label");
            detail_label.add_css_class ("drivewriter-numbers");
            detail_label.wrap = true;
            detail_label.justify = Justification.CENTER;
            box.append (detail_label);
            task_group = new PreferencesGroup ();
            task_group.width_request = 480;
            task_group.margin_top = 8;
            task_group.visible = false;
            box.append (task_group);
            var hint = new Label (_("Keep the drives connected until this is done."));
            hint.add_css_class ("dim-label");
            hint.add_css_class ("caption");
            hint.margin_top = 12;
            box.append (hint);
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = box;
            return scroll;
        }

        private Widget build_result () {
            result_page = new StatusPage ();
            var content = new Box (Orientation.VERTICAL, 12);
            result_group = new PreferencesGroup ();
            result_group.width_request = 420;
            result_group.halign = Align.CENTER;
            result_group.visible = false;
            content.append (result_group);
            var buttons = new Box (Orientation.HORIZONTAL, 12);
            buttons.halign = Align.CENTER;
            buttons.margin_top = 12;
            retry_button = new Button.with_label (_("Try Again"));
            retry_button.add_css_class ("pill");
            retry_button.clicked.connect (() => {
                if (return_page == "restore") show_restore ();
                else show_setup ();
            });
            buttons.append (retry_button);
            again_button = new Button.with_label (_("Write Another Image"));
            again_button.add_css_class ("pill");
            again_button.add_css_class ("suggested-action");
            again_button.clicked.connect (() => {
                image = null;
                chosen.clear ();
                set_expected (null, false);
                stack.visible_child_name = "welcome";
                sync ();
                choose_image ();
            });
            buttons.append (again_button);
            content.append (buttons);
            result_page.child = content;
            return result_page;
        }

        private async void connect_udisks () {
            try {
                client = yield UDisksClient.create ();
                client.changed.connect (on_drives_changed);
                exfat_available = yield client.can_format (FileSystemKind.EXFAT);
            } catch (Error e) {
                client = null;
                client_error = e.message;
            }
            client_loading = false;
            rebuild_drives ();
            rebuild_restore ();
        }

        private void on_drives_changed () {
            if (busy) {
                foreach (var t in tasks) {
                    if (t.finished || t.job == null || client.present (t.target)) continue;
                    t.removed = true;
                    t.job.cancel ();
                }
                return;
            }
            rebuild_drives ();
            rebuild_restore ();
        }

        public void choose_image () {
            if (busy) return;
            var dialog = new FileDialog ();
            dialog.title = _("Choose Disk Image");
            var filters = new GLib.ListStore (typeof (FileFilter));
            var images = new FileFilter ();
            images.name = _("Disk Images");
            foreach (string s in new string[] { "iso", "img", "raw", "bin", "xz", "gz", "zst" }) images.add_suffix (s);
            images.add_mime_type ("application/x-cd-image");
            images.add_mime_type ("application/x-raw-disk-image");
            images.add_mime_type ("application/x-raw-disk-image-xz-compressed");
            filters.append (images);
            var all = new FileFilter ();
            all.name = _("All Files");
            all.add_pattern ("*");
            filters.append (all);
            dialog.filters = filters;
            dialog.default_filter = images;
            string? downloads = Environment.get_user_special_dir (UserDirectory.DOWNLOAD);
            if (downloads != null) dialog.initial_folder = File.new_for_path (downloads);
            dialog.open.begin (this, null, (o, res) => {
                try {
                    var file = dialog.open.end (res);
                    if (file != null) set_image (file);
                } catch (Error e) {
                }
            });
        }

        public void set_image (File file) {
            if (busy) return;
            var info = new ImageInfo (file);
            try {
                info.inspect ();
            } catch (Error e) {
                show_error (_("The Image Cannot Be Opened"), e.message);
                return;
            }
            image = info;
            try {
                var fi = file.query_info (FileAttribute.STANDARD_ICON, FileQueryInfoFlags.NONE);
                image_icon.gicon = fi.get_icon ();
            } catch (Error e) {
                image_icon.icon_name = large_icon_name ("media-optical-symbolic");
            }
            image_name.label = info.name;
            image_detail.label = describe_image (info);
            image_problem.label = info.problem ?? "";
            image_problem.visible = info.problem != null;
            paste_row.text = "";
            set_expected (info.problem == null ? Sidecar.find (file) : null, false);
            show_setup ();
        }

        private static string describe_image (ImageInfo info) {
            string kind = info.kind.describe ();
            if (!info.kind.is_compressed ()) return _("%s, %s").printf (kind, Format.size (info.file_size));
            if (info.image_size >= 0) return _("%s, %s, %s when written").printf (kind, Format.size (info.file_size), Format.size ((uint64) info.image_size));
            return _("%s, %s").printf (kind, Format.size (info.file_size));
        }

        private static bool is_checksum_name (string name) {
            string n = name.down ();
            return n.has_suffix (".sha256") || n.has_suffix (".sha256sum") || n.has_suffix (".sha512") || n.contains ("sha256sums") || n.contains ("sha512sums") || n.has_suffix ("checksum") || n.has_suffix ("checksums");
        }

        private void set_expected (ExpectedHash? hash, bool from_paste) {
            if (hash_job != null && !busy) hash_job.cancellable.cancel ();
            expected = hash;
            expected_from_paste = from_paste && hash != null;
            check_state = hash != null ? CheckState.READY : CheckState.NONE;
            check_error = "";
            update_check_row ();
            sync ();
        }

        private void on_paste () {
            string text = paste_row.text.strip ();
            if (text == "") {
                if (expected_from_paste) set_expected (null, false);
                paste_row.subtitle = _("The SHA-256 value from the download page, or the lines of a SHA256SUMS file");
                return;
            }
            if (image == null) return;
            try {
                var list = ChecksumList.parse (text);
                set_expected (list.expected_for (image.name, _("the pasted text")), true);
                paste_row.subtitle = _("Checksum read");
            } catch (ChecksumError e) {
                paste_row.subtitle = (e is ChecksumError.NOT_LISTED) ? _("The pasted lines do not list %s.").printf (image.name) : _("This is not a SHA-256 checksum. It has 64 letters and digits.");
            }
        }

        private void choose_checksum () {
            if (busy || image == null) return;
            var dialog = new FileDialog ();
            dialog.title = _("Choose Checksum File");
            var filters = new GLib.ListStore (typeof (FileFilter));
            var sums = new FileFilter ();
            sums.name = _("Checksum Files");
            foreach (string p in new string[] { "*.sha256", "*.sha256sum", "*.sha512", "*SHA256SUMS*", "*sha256sums*", "*SHA512SUMS*", "*CHECKSUM*", "*.txt" }) sums.add_pattern (p);
            filters.append (sums);
            var all = new FileFilter ();
            all.name = _("All Files");
            all.add_pattern ("*");
            filters.append (all);
            dialog.filters = filters;
            dialog.default_filter = sums;
            var parent = image.file.get_parent ();
            if (parent != null) dialog.initial_folder = parent;
            dialog.open.begin (this, null, (o, res) => {
                try {
                    var file = dialog.open.end (res);
                    if (file != null) load_checksum_file (file);
                } catch (Error e) {
                }
            });
        }

        private void load_checksum_file (File file) {
            if (image == null) return;
            try {
                var info = file.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                if (info.get_size () > 4 * 1024 * 1024) throw new ChecksumError.INVALID (_("The checksum file is too large."));
                uint8[] data;
                file.load_contents (null, out data, null);
                string text = (string) data;
                if (!text.validate ()) throw new ChecksumError.INVALID (_("The file is not a text file."));
                var list = ChecksumList.parse (text);
                paste_row.text = "";
                set_expected (list.expected_for (image.name, file.get_basename () ?? ""), false);
            } catch (Error e) {
                show_error (_("The Checksum Cannot Be Used"), e.message);
            }
        }

        private static string short_hash (string hex) {
            return hex.length > 20 ? "%s…%s".printf (hex.substring (0, 12), hex.substring (hex.length - 8)) : hex;
        }

        private void update_check_row () {
            check_ring.visible = check_state == CheckState.CHECKING;
            check_stop.visible = check_state == CheckState.CHECKING && !busy;
            check_button.visible = expected != null && (check_state == CheckState.READY || check_state == CheckState.FAILED) && !busy;
            check_clear.visible = expected != null && check_state != CheckState.CHECKING && !busy;
            enable ("check-image", stack.visible_child_name == "setup" && !busy && expected != null && check_state != CheckState.CHECKING);
            switch (check_state) {
                case CheckState.READY:
                    check_row.title = _("%s from %s").printf (expected.algorithm (), expected.source);
                    check_row.subtitle = _("%s, compared before writing").printf (short_hash (expected.hex));
                    check_row.icon_name = "dialog-information-symbolic";
                    break;
                case CheckState.CHECKING:
                    check_row.title = _("Checking the Image");
                    check_row.icon_name = "dialog-information-symbolic";
                    break;
                case CheckState.MATCH:
                    check_row.title = _("The Image Matches Its Checksum");
                    check_row.subtitle = _("%s from %s").printf (expected.algorithm (), expected.source);
                    check_row.icon_name = "emblem-ok-symbolic";
                    break;
                case CheckState.MISMATCH:
                    check_row.title = _("The Image Does Not Match Its Checksum");
                    check_row.subtitle = _("It may be damaged or changed. Download it again, or check that the checksum belongs to this image.");
                    check_row.icon_name = "dialog-error-symbolic";
                    break;
                case CheckState.FAILED:
                    check_row.title = _("The Image Could Not Be Checked");
                    check_row.subtitle = check_error;
                    check_row.icon_name = "dialog-warning-symbolic";
                    break;
                default:
                    check_row.title = _("No Checksum");
                    check_row.subtitle = _("Paste the checksum from the download page, or choose its checksum file.");
                    check_row.icon_name = "dialog-question-symbolic";
                    break;
            }
        }

        private void on_hash_tick (HashJob job, bool on_page) {
            uint64 done = job.progress ();
            double fraction = job.total > 0 ? ((double) done / job.total).clamp (0, 1) : 0;
            if (on_page) {
                ring.fraction = fraction;
                ring.label = "%d%%".printf ((int) Math.floor (fraction * 100));
                detail_label.label = _("%s of %s checked").printf (Format.size (done), Format.size (job.total));
            } else {
                check_ring.fraction = fraction;
                check_row.subtitle = _("%s of %s checked").printf (Format.size (done), Format.size (job.total));
            }
        }

        private async bool run_check (bool on_page) {
            if (expected == null || image == null) return true;
            var job = new HashJob ();
            hash_job = job;
            check_state = CheckState.CHECKING;
            check_ring.fraction = 0;
            update_check_row ();
            uint ticker = Timeout.add (250, () => {
                on_hash_tick (job, on_page);
                return Source.CONTINUE;
            });
            bool cancelled = false;
            try {
                string actual = yield job.run (image.file, expected.kind);
                check_state = expected.matches (actual) ? CheckState.MATCH : CheckState.MISMATCH;
            } catch (Error e) {
                cancelled = e is IOError.CANCELLED;
                check_state = cancelled ? CheckState.READY : CheckState.FAILED;
                check_error = e.message;
            }
            Source.remove (ticker);
            if (hash_job == job) hash_job = null;
            update_check_row ();
            sync ();
            return !cancelled && check_state == CheckState.MATCH;
        }

        private async void check_now () {
            if (busy || expected == null || check_state == CheckState.CHECKING) return;
            yield run_check (false);
        }

        private void show_setup () {
            stack.visible_child_name = image != null ? "setup" : "welcome";
            rebuild_drives ();
        }

        public void show_restore () {
            if (busy) return;
            string current = stack.visible_child_name;
            if (current != "restore" && current != "result") return_page = current;
            else if (current == "result") return_page = image != null ? "setup" : "welcome";
            stack.visible_child_name = "restore";
            rebuild_restore ();
            sync ();
        }

        private void leave_restore () {
            if (busy) return;
            stack.visible_child_name = return_page == "setup" && image != null ? "setup" : "welcome";
            if (stack.visible_child_name == "setup") rebuild_drives ();
            sync ();
        }

        private Gee.List<TargetDrive> chosen_drives () {
            var list = new Gee.ArrayList<TargetDrive> ();
            foreach (var d in drives) if (chosen.contains (d.id)) list.add (d);
            return list;
        }

        private void rebuild_drives () {
            foreach (var r in drive_rows) drive_group.remove_row (r);
            drive_rows.clear ();
            checks.clear ();
            drives = client != null ? client.targets () : new Gee.ArrayList<TargetDrive> ();
            if (client == null || drives.size == 0) {
                if (client == null) {
                    no_drives.title = client_loading ? _("Looking for Drives") : _("Drives Are Not Available");
                    no_drives.description = client_loading ? "" : _("The disk service of this computer could not be reached. %s").printf (client_error);
                } else {
                    no_drives.title = _("No Drive Found");
                    no_drives.description = _("Insert a USB drive or memory card. It appears here as soon as it is ready.");
                }
                drive_stack.visible_child_name = "none";
                chosen.clear ();
                sync ();
                return;
            }
            drive_stack.visible_child_name = "list";
            var keep = new Gee.HashSet<string> ();
            keep.add_all (chosen);
            chosen.clear ();
            TargetDrive? only = null;
            int usable = 0;
            foreach (var d in drives) {
                var target = d;
                var row = new ActionRow (d.title, "%s, %s".printf (Format.size (d.size), d.device), "drive-removable-media-symbolic");
                var check = new CheckButton ();
                check.valign = Align.CENTER;
                row.add_suffix (check);
                bool too_small = image != null && image.fits (d.size) == Fit.TOO_LARGE;
                if (too_small) {
                    row.subtitle = _("%s, %s, too small for this image").printf (Format.size (d.size), d.device);
                    row.sensitive = false;
                } else {
                    usable++;
                    only = d;
                }
                row.activated.connect (() => check.active = !check.active);
                check.toggled.connect (() => {
                    if (check.active) chosen.add (target.id);
                    else chosen.remove (target.id);
                    sync ();
                });
                checks[d.id] = check;
                drive_group.add_row (row);
                drive_rows.add (row);
                if (keep.contains (d.id) && !too_small) check.active = true;
            }
            if (chosen.size == 0 && usable == 1 && drives.size == 1) checks[only.id].active = true;
            sync ();
        }

        private void rebuild_restore () {
            foreach (var r in restore_rows) restore_group.remove_row (r);
            restore_rows.clear ();
            var list = client != null ? client.targets () : new Gee.ArrayList<TargetDrive> ();
            if (list.size == 0) {
                restore_none.title = client == null ? (client_loading ? _("Looking for Drives") : _("Drives Are Not Available")) : _("No Drive Found");
                restore_none.description = client == null ? (client_loading ? "" : client_error) : _("Insert the USB drive or memory card to restore.");
                restore_stack.visible_child_name = "none";
                restore_id = null;
                sync_restore ();
                return;
            }
            restore_stack.visible_child_name = "list";
            string? keep = restore_id;
            restore_id = null;
            CheckButton? group = null;
            foreach (var d in list) {
                string id = d.id;
                var row = new ActionRow (d.title, "%s, %s".printf (Format.size (d.size), d.device), "drive-removable-media-symbolic");
                var check = new CheckButton ();
                check.valign = Align.CENTER;
                if (group != null) check.group = group;
                else group = check;
                row.add_suffix (check);
                row.activated.connect (() => check.active = true);
                check.toggled.connect (() => {
                    if (check.active) restore_id = id;
                    sync_restore ();
                });
                restore_group.add_row (row);
                restore_rows.add (row);
                if (id == keep || list.size == 1) check.active = true;
            }
            sync_restore ();
        }

        private FileSystemKind restore_kind () {
            return fs_row.current_value == "exFAT" ? FileSystemKind.EXFAT : FileSystemKind.FAT32;
        }

        private TargetDrive? restore_target () {
            if (restore_id == null || client == null) return null;
            foreach (var d in client.targets ()) if (d.id == restore_id) return d;
            return null;
        }

        private void sync_restore () {
            var kind = restore_kind ();
            fs_row.subtitle = kind == FileSystemKind.EXFAT
                ? _("For files larger than 4 GB. Works on recent computers, cameras and TVs.")
                : _("Works almost everywhere. Single files are limited to 4 GB.");
            string? label_problem = kind.check_label (kind.normalize_label (label_row.text));
            string? problem = null;
            if (kind == FileSystemKind.EXFAT && !exfat_available) problem = _("exFAT cannot be created on this computer. Choose FAT32.");
            label_row.subtitle = label_problem ?? (kind == FileSystemKind.FAT32 ? _("Up to 11 characters, shown in capitals") : _("Up to 15 characters"));
            if (label_problem != null) label_row.add_css_class ("error");
            else label_row.remove_css_class ("error");
            if (problem != null) fs_row.subtitle = problem;
            restore_bubble.sensitive = problem == null && label_problem == null && restore_id != null && !busy;
        }

        private void sync_mode_row () {
            mode_row.subtitle = settings.parallel ? _("All drives are written at the same time") : _("Drives are written one after the other");
            mode_row.visible = chosen.size > 1;
        }

        private void sync () {
            string page = stack.visible_child_name;
            bool setup = page == "setup";
            bool restore = page == "restore";
            open_bubble.visible = !busy && (setup || page == "result");
            back_bubble.visible = !busy && restore;
            cancel_bubble.visible = busy && !restoring;
            write_bubble.visible = setup && !busy;
            restore_bubble.visible = restore && !busy;
            if (restore) sync_restore ();
            var targets = chosen_drives ();
            bool fits = targets.size > 0;
            foreach (var d in targets) if (image != null && image.fits (d.size) == Fit.TOO_LARGE) fits = false;
            bool ready = image != null && image.problem == null && fits && check_state != CheckState.MISMATCH && check_state != CheckState.CHECKING;
            write_bubble.sensitive = ready;
            write_bubble.label = targets.size > 1 ? _("Write to %d Drives").printf (targets.size) : _("Write");
            sync_actions (setup, ready);
            if (mode_row != null) sync_mode_row ();
            string fit = "";
            if (setup && image != null && image.problem == null) {
                bool unknown = false;
                foreach (var d in targets) if (image.fits (d.size) == Fit.UNKNOWN) unknown = true;
                if (check_state == CheckState.MISMATCH) {
                    fit = _("Writing is blocked because the image does not match its checksum. Forget the checksum to write anyway.");
                } else if (unknown) {
                    fit = _("The size of this image is only known once it is decompressed. Writing stops if it does not fit.");
                } else if (drives.size > 0 && drive_rows.size > 0 && checks.size > 0) {
                    bool any = false;
                    foreach (var d in drives) if (image.fits (d.size) != Fit.TOO_LARGE) any = true;
                    if (!any) fit = _("The image is larger than every connected drive. Use a drive of at least %s.").printf (Format.size (image.display_size));
                }
            }
            fit_label.label = fit;
            fit_label.visible = fit != "";
        }

        private void confirm_write () {
            if (busy || image == null || image.problem != null || !write_bubble.sensitive) return;
            var targets = chosen_drives ();
            if (targets.size == 0) return;
            ConfirmDialog dlg;
            if (targets.size == 1) {
                var target = targets[0];
                dlg = new ConfirmDialog (app, _("Erase %s?").printf (target.title), "drive-removable-media",
                    _("Everything on %s (%s, %s) will be permanently erased and replaced by %s.").printf (target.title, Format.size (target.size), target.device, image.name),
                    _("Erase and Write"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            } else {
                string[] names = {};
                foreach (var t in targets) names += "%s (%s)".printf (t.title, t.device);
                dlg = new ConfirmDialog (app, ngettext ("Erase %d Drive?", "Erase %d Drives?", targets.size).printf (targets.size), "drive-multidisk",
                    _("Everything on these drives will be permanently erased and replaced by %s:").printf (image.name) + "\n" + string.joinv ("\n", names),
                    _("Erase and Write"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            }
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) run_all.begin (targets);
            });
            dlg.present ();
        }

        private void confirm_cancel () {
            if (!busy || restoring) {
                if (close_after && !busy) destroy ();
                else close_after = false;
                return;
            }
            var dlg = new ConfirmDialog (app, _("Stop Writing?"), "drive-removable-media",
                _("Drives that are being written are left partly written and will not work until they are written again or restored."),
                _("Stop"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) {
                    if (hash_job != null) hash_job.cancellable.cancel ();
                    foreach (var t in tasks) if (t.job != null) t.job.cancel ();
                    stopped = true;
                } else {
                    close_after = false;
                }
            });
            dlg.present ();
        }

        private bool stopped;

        private void begin_busy (string reason) {
            busy = true;
            stopped = false;
            ring.fraction = 0;
            ring.label = "";
            phase_label.label = _("Preparing");
            detail_label.label = "";
            target_label.label = "";
            task_group.visible = false;
            stack.visible_child_name = "progress";
            inhibit_cookie = app.inhibit (this, ApplicationInhibitFlags.SUSPEND | ApplicationInhibitFlags.LOGOUT, reason);
            update_check_row ();
            sync ();
        }

        private void end_busy () {
            busy = false;
            restoring = false;
            hash_job = null;
            if (inhibit_cookie != 0) app.uninhibit (inhibit_cookie);
            inhibit_cookie = 0;
            update_check_row ();
            sync ();
            update_launcher ();
            if (close_after) destroy ();
        }

        private double launcher_fraction = -1;

        private void update_launcher () {
            var conn = app.get_dbus_connection ();
            if (conn == null) return;
            bool visible = busy && !restoring;
            double fraction = visible ? ring.fraction.clamp (0, 1) : 0;
            if (visible && launcher_fraction >= 0 && Math.fabs (fraction - launcher_fraction) < 0.005) return;
            if (!visible && launcher_fraction < 0) return;
            launcher_fraction = visible ? fraction : -1;
            var props = new VariantBuilder (VariantType.VARDICT);
            props.add ("{sv}", "progress", new Variant.double (fraction));
            props.add ("{sv}", "progress-visible", new Variant.boolean (visible));
            if (visible) props.add ("{sv}", "label", new Variant.string (phase_label.label));
            try {
                conn.emit_signal (null, "/com/canonical/Unity/LauncherEntry", "com.canonical.Unity.LauncherEntry", "Update",
                    new Variant ("(s@a{sv})", "application://dev.sinty.drivewriter.desktop", props.end ()));
            } catch (Error e) {
                warning ("drivewriter: %s", e.message);
            }
        }

        private void build_task_rows () {
            foreach (var r in task_rows) task_group.remove_row (r);
            task_rows.clear ();
            foreach (var t in tasks) {
                var row = new ActionRow (t.target.title, _("Waiting"), "drive-removable-media-symbolic");
                row.activatable = false;
                var r = new CircularProgress (32);
                r.valign = Align.CENTER;
                r.add_css_class ("drivewriter-task-ring");
                row.add_suffix (r);
                t.row = row;
                t.ring = r;
                task_group.add_row (row);
                task_rows.add (row);
            }
            task_group.visible = tasks.size > 1;
        }

        private async void run_all (Gee.List<TargetDrive> targets) {
            return_page = "setup";
            begin_busy (ngettext ("Writing a disk image", "Writing a disk image to several drives", targets.size));
            target_label.label = targets.size == 1 ? _("%s to %s").printf (image.name, targets[0].title) : ngettext ("%s to %d drive", "%s to %d drives", targets.size).printf (image.name, targets.size);
            if (expected != null && check_state != CheckState.MATCH) {
                phase_label.label = _("Checking the Image");
                bool ok = yield run_check (true);
                if (!ok) {
                    if (check_state == CheckState.MISMATCH) {
                        finish_error (_("The Image Does Not Match Its Checksum"), _("Nothing was written. %s may be damaged or changed. Download it again, or check that the checksum belongs to this image.").printf (image.name));
                    } else if (stopped || check_state == CheckState.READY) {
                        finish_error (_("Writing Stopped"), _("Nothing was written."));
                    } else {
                        finish_error (_("The Image Could Not Be Checked"), check_error);
                    }
                    return;
                }
            }
            tasks.clear ();
            foreach (var t in targets) tasks.add (new DriveTask (t));
            build_task_rows ();
            ring.fraction = 0;
            ring.label = "";
            phase_label.label = tasks.size == 1 ? _("Writing") : ngettext ("Writing %d Drive", "Writing %d Drives", tasks.size).printf (tasks.size);
            if (settings.parallel && tasks.size > 1) {
                int pending = tasks.size;
                SourceFunc callback = run_all.callback;
                foreach (var t in tasks) {
                    run_task.begin (t, (o, res) => {
                        run_task.end (res);
                        pending--;
                        if (pending == 0) Idle.add ((owned) callback);
                    });
                }
                yield;
            } else {
                foreach (var t in tasks) {
                    if (stopped) {
                        t.finished = true;
                        t.failure_title = _("Not Written");
                        t.failure = _("Writing was stopped before this drive.");
                        set_task_state (t, t.failure);
                        continue;
                    }
                    yield run_task (t);
                }
            }
            show_summary ();
        }

        private void set_task_state (DriveTask t, string text) {
            if (t.row != null) t.row.subtitle = text;
        }

        private void refresh_overall () {
            if (tasks.size <= 1) return;
            double sum = 0;
            foreach (var t in tasks) sum += t.overall (settings.verify);
            double fraction = sum / tasks.size;
            ring.fraction = fraction;
            ring.label = "%d%%".printf ((int) Math.floor (fraction * 100));
            int done = 0;
            foreach (var t in tasks) if (t.finished) done++;
            detail_label.label = ngettext ("%d of %d drive finished", "%d of %d drives finished", tasks.size).printf (done, tasks.size);
        }

        private async void run_task (DriveTask t) {
            var target = t.target;
            t.job = new WriteJob (image);
            t.job.progress.connect ((phase, fraction, bytes, rate, seconds_left) => on_task_progress (t, phase, fraction, bytes, rate, seconds_left));
            set_task_state (t, _("Preparing"));
            try {
                yield client.release (target);
            } catch (Error e) {
                fail_task (t, _("The Drive Is in Use"), _("A partition on the drive could not be unmounted. Close the files and apps that use it and try again.") + "\n" + clean_message (e));
                return;
            }
            int fd;
            try {
                fd = yield client.open_for (target, "OpenForRestore");
            } catch (Error e) {
                fail_with (t, e);
                return;
            }
            if (t.job.cancellable.is_cancelled ()) {
                Posix.close (fd);
                fail_task (t, _("Writing Stopped"), _("Nothing was written to %s.").printf (target.title));
                return;
            }
            try {
                yield t.job.write (fd);
            } catch (Error e) {
                Posix.close (fd);
                fail_with (t, e);
                return;
            }
            Posix.close (fd);
            if (settings.verify && !t.job.cancellable.is_cancelled ()) {
                t.phase = Phase.VERIFYING;
                t.fraction = 0;
                if (tasks.size == 1) {
                    phase_label.label = _("Checking");
                    ring.fraction = 0;
                }
                set_task_state (t, _("Checking"));
                try {
                    int rfd = yield client.open_for (target, "OpenForBackup");
                    try {
                        yield t.job.verify (rfd);
                    } finally {
                        Posix.close (rfd);
                    }
                    t.verified = true;
                } catch (Error e) {
                    fail_with (t, e);
                    return;
                }
            }
            if (tasks.size == 1) {
                phase_label.label = _("Ejecting");
                detail_label.label = "";
            }
            set_task_state (t, _("Ejecting"));
            t.ejected = yield client.eject (target);
            t.ok = true;
            t.finished = true;
            if (t.ring != null) {
                t.ring.fraction = 1;
                t.ring.label = "";
            }
            if (t.row != null) t.row.icon_name = "emblem-ok-symbolic";
            set_task_state (t, t.verified ? _("Written and checked") : _("Written"));
            refresh_overall ();
        }

        private void on_task_progress (DriveTask t, Phase phase, double fraction, uint64 bytes, double rate, int64 seconds_left) {
            t.phase = phase;
            t.fraction = fraction;
            var parts = new Gee.ArrayList<string> ();
            if (phase == Phase.WRITING) parts.add (_("%s written").printf (Format.size (bytes)));
            else parts.add (_("%s of %s checked").printf (Format.size (bytes), Format.size (t.job != null ? t.job.written : bytes)));
            if (rate > 0) parts.add (Format.rate (rate));
            if (fraction >= 0.999 && phase == Phase.WRITING) parts.add (_("finishing"));
            else if (seconds_left >= 0) parts.add (Format.time_left (seconds_left));
            string text = string.joinv (", ", parts.to_array ());
            if (t.ring != null) {
                t.ring.fraction = t.overall (settings.verify);
                t.ring.label = "";
            }
            set_task_state (t, (phase == Phase.WRITING ? _("Writing") : _("Checking")) + ", " + text);
            if (tasks.size == 1) {
                ring.fraction = fraction;
                ring.label = "%d%%".printf ((int) Math.floor (fraction * 100));
                detail_label.label = text;
            } else {
                refresh_overall ();
            }
        }

        private void fail_task (DriveTask t, string title, string message) {
            t.finished = true;
            t.ok = false;
            t.failure_title = title;
            t.failure = message;
            if (t.row != null) t.row.icon_name = "dialog-error-symbolic";
            set_task_state (t, title);
            refresh_overall ();
        }

        private void fail_with (DriveTask t, Error e) {
            var target = t.target;
            if (t.removed || (client != null && !client.present (target))) {
                fail_task (t, _("The Drive Was Removed"), _("%s was disconnected while it was being written. Connect it again and write the image once more.").printf (target.title));
            } else if (e is IOError.CANCELLED && t.phase == Phase.VERIFYING) {
                fail_task (t, _("Check Stopped"), _("The image was written to %s, but it was not checked.").printf (target.title));
            } else if (e is IOError.CANCELLED) {
                fail_task (t, _("Writing Stopped"), _("%s is only partly written and will not work until it is written again or restored.").printf (target.title));
            } else if (e is WriteError.NO_SPACE) {
                fail_task (t, _("The Image Does Not Fit"), _("%s is too small for %s. Use a larger drive.").printf (target.title, image.name));
            } else if (e is WriteError.MISMATCH || e is WriteError.SHORT_READ) {
                fail_task (t, _("The Check Failed"), e.message);
            } else if (not_authorized (e)) {
                fail_task (t, _("Permission Denied"), _("Writing to %s was not allowed.").printf (target.title));
            } else if (e is IOError.INVALID_DATA) {
                fail_task (t, _("The Image Is Damaged"), e.message + "\n" + _("Download the image again."));
            } else {
                fail_task (t, _("Writing Failed"), clean_message (e));
            }
        }

        private void clear_result_rows () {
            foreach (var r in result_rows) result_group.remove_row (r);
            result_rows.clear ();
            result_group.visible = false;
        }

        private void show_summary () {
            int good = 0;
            foreach (var t in tasks) if (t.ok) good++;
            clear_result_rows ();
            if (tasks.size == 1) {
                var t = tasks[0];
                if (!t.ok) {
                    finish_error (t.failure_title, t.failure);
                    return;
                }
                result_page.icon_name = "dev.sinty.drivewriter";
                result_page.title = _("Done");
                string what = _("%s of %s were written to %s.").printf (Format.size (t.job.written), image.name, t.target.title);
                if (t.verified) what += " " + _("The drive was checked and matches the image.");
                if (check_state == CheckState.MATCH) what += " " + _("The image matched its checksum.");
                result_page.description = what + "\n" + (t.ejected ? _("You can remove the drive now.") : _("Eject the drive before you remove it."));
            } else {
                foreach (var t in tasks) {
                    string sub = t.ok ? (t.verified ? _("Written and checked") : _("Written")) + (t.ejected ? ", " + _("ejected") : "") : t.failure;
                    var row = new ActionRow (t.target.title, sub, t.ok ? "emblem-ok-symbolic" : "dialog-error-symbolic");
                    row.activatable = false;
                    result_group.add_row (row);
                    result_rows.add (row);
                }
                result_group.visible = true;
                if (good == tasks.size) {
                    result_page.icon_name = "dev.sinty.drivewriter";
                    result_page.title = _("Done");
                    result_page.description = ngettext ("%s was written to %d drive.", "%s was written to %d drives.", tasks.size).printf (image.name, tasks.size);
                } else {
                    result_page.icon_name = good == 0 ? "dialog-error" : "dialog-warning";
                    result_page.title = good == 0 ? _("Writing Failed") : _("Some Drives Failed");
                    result_page.description = _("%d of %d drives were written. Check the failed drives and try them again.").printf (good, tasks.size);
                }
            }
            retry_button.visible = good < tasks.size;
            again_button.visible = good == tasks.size;
            again_button.label = _("Write Another Image");
            stack.visible_child_name = "result";
            end_busy ();
            rebuild_drives ();
        }

        private static string clean_message (Error e) {
            if (e is DBusError) DBusError.strip_remote_error (e);
            return e.message;
        }

        private static bool not_authorized (Error e) {
            if (e is DBusError.ACCESS_DENIED || e is DBusError.AUTH_FAILED) return true;
            string? remote = DBusError.get_remote_error (e);
            return remote != null && (remote.has_suffix ("NotAuthorized") || remote.has_suffix ("NotAuthorizedCanObtain") || remote.has_suffix ("NotAuthorizedDismissed"));
        }

        private void finish_error (string title, string message) {
            clear_result_rows ();
            result_page.icon_name = "dialog-error";
            result_page.title = title;
            result_page.description = message;
            retry_button.visible = return_page == "restore" || image != null;
            again_button.visible = false;
            stack.visible_child_name = "result";
            end_busy ();
            rebuild_drives ();
            rebuild_restore ();
        }

        private void confirm_restore () {
            var target = restore_target ();
            if (busy || target == null || !restore_bubble.sensitive) return;
            var kind = restore_kind ();
            string name = kind.normalize_label (label_row.text);
            string layout = name != "" ? _("It will get one %s partition named %s, ready for files.").printf (kind.label (), name) : _("It will get one empty %s partition, ready for files.").printf (kind.label ());
            var dlg = new ConfirmDialog (app, _("Erase %s?").printf (target.title), "drive-removable-media",
                _("Everything on %s (%s, %s) will be permanently erased.").printf (target.title, Format.size (target.size), target.device) + " " + layout,
                _("Erase and Restore"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) run_restore.begin (target, kind, name);
            });
            dlg.present ();
        }

        private async void run_restore (TargetDrive target, FileSystemKind kind, string name) {
            return_page = "restore";
            restoring = true;
            begin_busy (_("Restoring a drive"));
            phase_label.label = _("Restoring");
            target_label.label = _("%s, %s").printf (target.title, kind.label ());
            detail_label.label = _("Erasing the drive and creating the new partition");
            ring.fraction = 0;
            double pulse = 0;
            uint spinner = Timeout.add (60, () => {
                pulse = (pulse + 0.02) % 1.0;
                ring.fraction = pulse;
                return Source.CONTINUE;
            });
            Error? failure = null;
            try {
                yield client.restore (target, kind, name);
            } catch (Error e) {
                failure = e;
            }
            Source.remove (spinner);
            if (failure != null) {
                if (not_authorized (failure)) finish_error (_("Permission Denied"), _("Restoring %s was not allowed.").printf (target.title));
                else if (client != null && !client.present (target)) finish_error (_("The Drive Was Removed"), _("%s was disconnected. Connect it again and restore it once more.").printf (target.title));
                else finish_error (_("The Drive Could Not Be Restored"), clean_message (failure));
                return;
            }
            clear_result_rows ();
            result_page.icon_name = "drive-removable-media";
            result_page.title = _("The Drive Is Ready");
            result_page.description = name != ""
                ? _("%s now has one %s partition named %s and can hold files again.").printf (target.title, kind.label (), name)
                : _("%s now has one %s partition and can hold files again.").printf (target.title, kind.label ());
            retry_button.visible = false;
            again_button.visible = true;
            again_button.label = image != null ? _("Write Another Image") : _("Choose Image");
            stack.visible_child_name = "result";
            end_busy ();
            rebuild_restore ();
        }

        private void show_error (string title, string message) {
            var dlg = new ConfirmDialog.message (app, title, "dialog-error", message);
            dlg.transient_for = this;
            dlg.present ();
        }

        private void sync_actions (bool setup, bool ready) {
            enable ("open", !busy);
            enable ("write", setup && !busy && ready);
            enable ("cancel", busy && !restoring);
            enable ("refresh", !busy);
            enable ("open-checksum", setup && !busy);
            enable ("check-image", setup && !busy && expected != null && check_state != CheckState.CHECKING);
            enable ("select-all", setup && !busy);
            enable ("restore", !busy);
        }

        private void enable (string name, bool on) {
            var a = lookup_action (name) as SimpleAction;
            if (a != null) a.set_enabled (on);
        }

        private void install_actions () {
            var close_action = new SimpleAction ("close", null);
            close_action.activate.connect (() => close ());
            add_action (close_action);
            var open = new SimpleAction ("open", null);
            open.activate.connect (() => choose_image ());
            add_action (open);
            var write = new SimpleAction ("write", null);
            write.activate.connect (() => {
                if (stack.visible_child_name == "setup" && write_bubble.sensitive) confirm_write ();
            });
            add_action (write);
            var cancel = new SimpleAction ("cancel", null);
            cancel.activate.connect (() => confirm_cancel ());
            add_action (cancel);
            var verify = new SimpleAction.stateful ("verify", null, new Variant.boolean (settings.verify));
            verify.activate.connect (() => {
                settings.verify = !settings.verify;
                verify.set_state (new Variant.boolean (settings.verify));
            });
            settings.notify["verify"].connect (() => verify.set_state (new Variant.boolean (settings.verify)));
            add_action (verify);
            var refresh = new SimpleAction ("refresh", null);
            refresh.activate.connect (() => {
                if (busy) return;
                rebuild_drives ();
                rebuild_restore ();
            });
            add_action (refresh);
            var checksum = new SimpleAction ("open-checksum", null);
            checksum.activate.connect (() => {
                if (stack.visible_child_name == "setup") choose_checksum ();
            });
            add_action (checksum);
            var check = new SimpleAction ("check-image", null);
            check.activate.connect (() => {
                if (stack.visible_child_name == "setup") check_now.begin ();
            });
            add_action (check);
            var restore = new SimpleAction ("restore", null);
            restore.activate.connect (() => show_restore ());
            add_action (restore);
            var select_all = new SimpleAction ("select-all", null);
            select_all.activate.connect (() => {
                if (busy || stack.visible_child_name != "setup") return;
                foreach (var d in drives) {
                    var c = checks[d.id];
                    if (c != null && c.get_parent () != null && ((Widget) c).is_sensitive ()) c.active = true;
                }
            });
            add_action (select_all);
        }
    }
}
