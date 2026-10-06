namespace Singularity.Apps.DriveWriter {

    public class Format : Object {
        public static string size (uint64 bytes) {
            return GLib.format_size (bytes);
        }

        public static string rate (double bytes_per_second) {
            return _("%s/s").printf (GLib.format_size ((uint64) bytes_per_second));
        }

        public static string time_left (int64 seconds) {
            if (seconds < 0) return "";
            if (seconds < 60) return _("less than a minute left");
            int64 minutes = (seconds + 59) / 60;
            if (minutes < 60) return ngettext ("%d minute left", "%d minutes left", (ulong) minutes).printf ((int) minutes);
            int64 hours = minutes / 60;
            int64 rest = minutes % 60;
            if (rest == 0) return ngettext ("%d hour left", "%d hours left", (ulong) hours).printf ((int) hours);
            return _("%d h %d min left").printf ((int) hours, (int) rest);
        }
    }
}
