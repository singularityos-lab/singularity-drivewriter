using Gtk;

namespace Singularity.Apps.DriveWriter {

    public class DriveWriterApp : Singularity.Application {
        private bool restore_pending;

        public DriveWriterApp () {
            Object (application_id: "dev.sinty.drivewriter", flags: ApplicationFlags.HANDLES_OPEN);
            add_main_option ("restore", 0, OptionFlags.NONE, OptionArg.NONE, _("Erase a drive that holds an image"), null);
        }

        protected override int handle_local_options (VariantDict options) {
            if (!options.contains ("restore")) return -1;
            try {
                register (null);
            } catch (Error e) {
                warning ("drivewriter: %s", e.message);
                return 1;
            }
            if (get_is_remote ()) {
                activate_action ("restore-drive", null);
                return 0;
            }
            restore_pending = true;
            return -1;
        }

        protected override void startup () {
            base.startup ();
            var provider = new CssProvider ();
            provider.load_from_string (CSS);
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, STYLE_PROVIDER_PRIORITY_USER + 1);
            var menu = new GLib.Menu ();
            var file = new GLib.Menu ();
            var f1 = new GLib.Menu ();
            f1.append (_("Choose Image…"), "win.open");
            f1.append (_("Choose Checksum File…"), "win.open-checksum");
            f1.append (_("Write to Drive…"), "win.write");
            f1.append (_("Stop Writing"), "win.cancel");
            file.append_section (null, f1);
            var f3 = new GLib.Menu ();
            f3.append (_("Restore a Drive…"), "win.restore");
            file.append_section (null, f3);
            var f2 = new GLib.Menu ();
            f2.append (_("Close Window"), "win.close");
            f2.append (_("Quit"), "app.quit");
            file.append_section (null, f2);
            menu.append_submenu (_("File"), file);
            var edit = new GLib.Menu ();
            var e1 = new GLib.Menu ();
            e1.append (_("Check the Image Now"), "win.check-image");
            e1.append (_("Select All Drives"), "win.select-all");
            e1.append (_("Check the Drive After Writing"), "win.verify");
            edit.append_section (null, e1);
            var e2 = new GLib.Menu ();
            e2.append (_("Settings"), "app.settings");
            edit.append_section (null, e2);
            menu.append_submenu (_("Edit"), edit);
            var view = new GLib.Menu ();
            view.append (_("Refresh Drives"), "win.refresh");
            menu.append_submenu (_("View"), view);
            set_menubar (menu);
            var quit = new SimpleAction ("quit", null);
            quit.activate.connect (() => {
                foreach (var w in get_windows ()) w.close ();
            });
            add_action (quit);
            var settings_action = new SimpleAction ("settings", null);
            settings_action.activate.connect (() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings ("dev.sinty.drivewriter");
                } catch (Error e) {
                    warning ("Failed to open settings: %s", e.message);
                }
            });
            add_action (settings_action);
            var write_image = new SimpleAction ("write-image", new VariantType ("as"));
            write_image.activate.connect ((param) => {
                string[] uris = param.get_strv ();
                if (uris.length == 0) return;
                open ({ File.new_for_uri (uris[0]) }, "");
            });
            add_action (write_image);
            var restore_drive = new SimpleAction ("restore-drive", null);
            restore_drive.activate.connect (() => {
                activate ();
                var w = get_active_window () as WriterWindow;
                if (w != null) w.show_restore ();
            });
            add_action (restore_drive);
            set_accels_for_action ("app.quit", { "<Control>q" });
            set_accels_for_action ("app.settings", { "<Control>comma" });
            set_accels_for_action ("win.close", { "<Control>w" });
            set_accels_for_action ("win.open", { "<Control>o" });
            set_accels_for_action ("win.write", { "<Control>Return" });
            set_accels_for_action ("win.cancel", { "<Control>period" });
            set_accels_for_action ("win.refresh", { "<Control>r", "F5" });
            set_accels_for_action ("win.open-checksum", { "<Control><Shift>o" });
            set_accels_for_action ("win.check-image", { "<Control>k" });
            set_accels_for_action ("win.select-all", { "<Control><Shift>a" });
            set_accels_for_action ("win.restore", { "<Control><Shift>r" });
        }

        public override void activate () {
            var w = get_active_window ();
            if (w == null) w = new WriterWindow (this);
            w.present ();
            if (restore_pending) {
                restore_pending = false;
                ((WriterWindow) w).show_restore ();
            }
        }

        public override void open (File[] files, string hint) {
            activate ();
            var w = get_active_window () as WriterWindow;
            if (w != null && files.length > 0) w.set_image (files[0]);
        }

        private const string CSS = """
.drivewriter-ring {
    color: @accent_bg_color;
    font-size: 22px;
    font-weight: 700;
}

.drivewriter-task-ring {
    color: @accent_bg_color;
}

.drivewriter-numbers {
    font-feature-settings: "tnum";
}
""";
    }

    public static int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = FileUtils.read_link ("/proc/self/exe");
            locale_dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale");
        } catch (Error e) {
        }
        Intl.bindtextdomain ("singularity-drivewriter", locale_dir);
        Intl.bind_textdomain_codeset ("singularity-drivewriter", "UTF-8");
        Intl.textdomain ("singularity-drivewriter");
        return new DriveWriterApp ().run (args);
    }
}
