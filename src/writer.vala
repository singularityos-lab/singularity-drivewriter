namespace Singularity.Apps.DriveWriter {

    [CCode (cname = "posix_fadvise", cheader_filename = "fcntl.h")]
    private extern int fadvise (int fd, int64 offset, int64 len, int advice);

    public errordomain WriteError {
        NO_SPACE,
        WRITE_FAILED,
        READ_FAILED,
        SHORT_READ,
        MISMATCH
    }

    public enum Phase {
        WRITING,
        VERIFYING
    }

    public delegate void Tick (uint64 bytes);

    public class Copier : Object {
        public const int BUFFER = 4 * 1024 * 1024;
        private const int FADV_DONTNEED = 4;

        public static string write_stream (InputStream source, int fd, Cancellable? cancel, Tick? tick, out uint64 written) throws Error {
            written = 0;
            var checksum = new Checksum (ChecksumType.SHA256);
            var buffer = new uint8[BUFFER];
            while (true) {
                if (cancel != null) cancel.set_error_if_cancelled ();
                size_t got;
                source.read_all (buffer, out got, cancel);
                if (got == 0) break;
                write_all (fd, buffer, got);
                checksum.update (buffer, got);
                written += got;
                if (tick != null) tick (written);
                if (got < BUFFER) break;
            }
            if (cancel != null) cancel.set_error_if_cancelled ();
            if (Posix.fsync (fd) != 0 && errno != Posix.EINVAL) {
                throw new WriteError.WRITE_FAILED (_("Writing failed: %s"), Posix.strerror (errno));
            }
            return checksum.get_string ();
        }

        private static void write_all (int fd, uint8[] buffer, size_t length) throws Error {
            size_t offset = 0;
            while (offset < length) {
                ssize_t w = Posix.write (fd, (uint8*) buffer + offset, length - offset);
                if (w < 0) {
                    if (errno == Posix.EINTR) continue;
                    if (errno == Posix.ENOSPC || errno == Posix.EFBIG) throw new WriteError.NO_SPACE (_("The image is larger than the drive."));
                    throw new WriteError.WRITE_FAILED (_("Writing failed: %s"), Posix.strerror (errno));
                }
                if (w == 0) throw new WriteError.NO_SPACE (_("The image is larger than the drive."));
                offset += w;
            }
        }

        public static string read_back (int fd, uint64 length, Cancellable? cancel, Tick? tick) throws Error {
            fadvise (fd, 0, 0, FADV_DONTNEED);
            if (Posix.lseek (fd, 0, Posix.SEEK_SET) < 0) throw new WriteError.READ_FAILED (_("Reading the drive failed: %s"), Posix.strerror (errno));
            var checksum = new Checksum (ChecksumType.SHA256);
            var buffer = new uint8[BUFFER];
            uint64 done = 0;
            while (done < length) {
                if (cancel != null) cancel.set_error_if_cancelled ();
                size_t want = (size_t) uint64.min (BUFFER, length - done);
                ssize_t n = Posix.read (fd, buffer, want);
                if (n < 0) {
                    if (errno == Posix.EINTR) continue;
                    throw new WriteError.READ_FAILED (_("Reading the drive failed: %s"), Posix.strerror (errno));
                }
                if (n == 0) throw new WriteError.SHORT_READ (_("The drive holds less data than was written to it."));
                checksum.update (buffer, (size_t) n);
                done += n;
                if (tick != null) tick (done);
            }
            return checksum.get_string ();
        }

        public static void verify (int fd, string expected, uint64 length, Cancellable? cancel, Tick? tick) throws Error {
            string actual = read_back (fd, length, cancel, tick);
            if (actual != expected) throw new WriteError.MISMATCH (_("The data on the drive does not match the image. The drive may be faulty."));
        }
    }

    public class RateMeter : Object {
        private const int64 WINDOW = 5000000;
        private Gee.ArrayList<int64?> times = new Gee.ArrayList<int64?> ();
        private Gee.ArrayList<uint64?> values = new Gee.ArrayList<uint64?> ();

        public void add (int64 time_us, uint64 value) {
            times.add (time_us);
            values.add (value);
            while (times.size > 2 && time_us - times[0] > WINDOW) {
                times.remove_at (0);
                values.remove_at (0);
            }
        }

        public double rate () {
            if (times.size < 2) return 0;
            int64 span = times[times.size - 1] - times[0];
            if (span <= 0) return 0;
            uint64 last = values[values.size - 1], first = values[0];
            if (last <= first) return 0;
            return (last - first) * 1000000.0 / span;
        }

        public static int64 seconds_left (uint64 done, uint64 total, double rate) {
            if (rate <= 0 || done >= total) return -1;
            return (int64) Math.ceil ((total - done) / rate);
        }
    }

    public class WriteJob : Object {
        public ImageInfo image { get; construct; }
        public Cancellable cancellable { get; private set; }
        public uint64 written { get; private set; }
        public string checksum { get; private set; default = ""; }

        private Mutex mutex = Mutex ();
        private uint64 bytes_done;
        private uint64 position_done;
        private uint ticker;
        private RateMeter bytes_meter;
        private RateMeter position_meter;

        public signal void progress (Phase phase, double fraction, uint64 bytes, double rate, int64 seconds_left);

        public WriteJob (ImageInfo image) {
            Object (image: image);
            cancellable = new Cancellable ();
        }

        public void cancel () {
            cancellable.cancel ();
        }

        private void start_ticker (Phase phase, uint64 total) {
            bytes_meter = new RateMeter ();
            position_meter = new RateMeter ();
            bytes_done = 0;
            position_done = 0;
            ticker = Timeout.add (250, () => {
                emit_progress (phase, total);
                return Source.CONTINUE;
            });
        }

        private void emit_progress (Phase phase, uint64 total) {
            mutex.lock ();
            uint64 bytes = bytes_done, position = position_done;
            mutex.unlock ();
            int64 now = get_monotonic_time ();
            bytes_meter.add (now, bytes);
            position_meter.add (now, position);
            double fraction = total > 0 ? (double) position / total : 0;
            progress (phase, fraction.clamp (0, 1), bytes, bytes_meter.rate (), RateMeter.seconds_left (position, total, position_meter.rate ()));
        }

        private void stop_ticker (Phase phase, uint64 total) {
            if (ticker != 0) Source.remove (ticker);
            ticker = 0;
            emit_progress (phase, total);
        }

        public async void write (int fd) throws Error {
            var source = new ImageSource (image);
            uint64 total = image.file_size;
            start_ticker (Phase.WRITING, total);
            Error? failure = null;
            string? hash = null;
            uint64 count = 0;
            SourceFunc callback = write.callback;
            new Thread<bool> ("drivewriter-write", () => {
                try {
                    hash = Copier.write_stream (source.stream, fd, cancellable, (n) => {
                        uint64 at = source.position ();
                        mutex.lock ();
                        bytes_done = n;
                        position_done = at;
                        mutex.unlock ();
                    }, out count);
                } catch (Error e) {
                    failure = e;
                }
                source.close ();
                Idle.add ((owned) callback);
                return true;
            });
            yield;
            stop_ticker (Phase.WRITING, total);
            if (failure != null) throw failure;
            written = count;
            checksum = hash;
        }

        public async void verify (int fd) throws Error {
            start_ticker (Phase.VERIFYING, written);
            Error? failure = null;
            SourceFunc callback = verify.callback;
            new Thread<bool> ("drivewriter-verify", () => {
                try {
                    Copier.verify (fd, checksum, written, cancellable, (n) => {
                        mutex.lock ();
                        bytes_done = n;
                        position_done = n;
                        mutex.unlock ();
                    });
                } catch (Error e) {
                    failure = e;
                }
                Idle.add ((owned) callback);
                return true;
            });
            yield;
            stop_ticker (Phase.VERIFYING, written);
            if (failure != null) throw failure;
        }
    }
}
