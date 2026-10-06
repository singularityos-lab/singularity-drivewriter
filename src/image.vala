namespace Singularity.Apps.DriveWriter {

    public enum ImageKind {
        UNKNOWN,
        RAW,
        ISO,
        DISK,
        XZ,
        GZIP,
        ZSTD,
        BZIP2,
        ZIP;

        public bool is_compressed () {
            return this == XZ || this == GZIP || this == ZSTD;
        }

        public bool is_supported () {
            switch (this) {
                case XZ: return DecoderBridge.available (DecoderBridge.KIND_XZ);
                case ZSTD: return DecoderBridge.available (DecoderBridge.KIND_ZSTD);
                case BZIP2:
                case ZIP: return false;
                default: return true;
            }
        }

        public string describe () {
            switch (this) {
                case RAW: return _("Disk image");
                case ISO: return _("ISO image");
                case DISK: return _("Disk image");
                case XZ: return _("Disk image, xz compressed");
                case GZIP: return _("Disk image, gzip compressed");
                case ZSTD: return _("Disk image, Zstandard compressed");
                case BZIP2: return _("bzip2 archive");
                case ZIP: return _("ZIP archive");
                default: return _("Unknown file");
            }
        }
    }

    public enum Fit {
        FITS,
        TOO_LARGE,
        UNKNOWN
    }

    public class ImageInfo : Object {
        public const int HEAD_SIZE = 0x8800;

        public File file { get; construct; }
        public string name { get; construct; }
        public ImageKind kind { get; private set; default = ImageKind.UNKNOWN; }
        public uint64 file_size { get; private set; }
        public int64 image_size { get; private set; default = -1; }
        public string? problem { get; private set; }

        public ImageInfo (File file) {
            Object (file: file, name: file.get_basename () ?? file.get_uri ());
        }

        public uint64 display_size {
            get { return image_size >= 0 ? (uint64) image_size : file_size; }
        }

        public static ImageKind detect (uint8[] head, string name) {
            if (starts_with (head, 0, { 0xFD, '7', 'z', 'X', 'Z', 0x00 })) return ImageKind.XZ;
            if (starts_with (head, 0, { 0x1F, 0x8B })) return ImageKind.GZIP;
            if (starts_with (head, 0, { 0x28, 0xB5, 0x2F, 0xFD })) return ImageKind.ZSTD;
            if (starts_with (head, 0, { 'B', 'Z', 'h' })) return ImageKind.BZIP2;
            if (starts_with (head, 0, { 'P', 'K', 0x03, 0x04 })) return ImageKind.ZIP;
            if (starts_with (head, 0x8001, { 'C', 'D', '0', '0', '1' })) return ImageKind.ISO;
            if (starts_with (head, 512, { 'E', 'F', 'I', ' ', 'P', 'A', 'R', 'T' })) return ImageKind.DISK;
            if (starts_with (head, 510, { 0x55, 0xAA })) return ImageKind.DISK;
            string lower = name.down ();
            foreach (string ext in new string[] { ".img", ".raw", ".iso", ".bin", ".dd" }) {
                if (lower.has_suffix (ext)) return ImageKind.RAW;
            }
            return ImageKind.UNKNOWN;
        }

        private static bool starts_with (uint8[] data, int offset, uint8[] magic) {
            if (data.length < offset + magic.length) return false;
            for (int i = 0; i < magic.length; i++) {
                if (data[offset + i] != magic[i]) return false;
            }
            return true;
        }

        public static Fit check_fit (int64 image_size, uint64 drive_size) {
            if (image_size < 0) return Fit.UNKNOWN;
            return (uint64) image_size <= drive_size ? Fit.FITS : Fit.TOO_LARGE;
        }

        public Fit fits (uint64 drive_size) {
            if (kind.is_compressed ()) return check_fit (image_size, drive_size);
            return check_fit ((int64) file_size, drive_size);
        }

        public void inspect () throws Error {
            string? path = file.get_path ();
            if (path == null) throw new IOError.NOT_SUPPORTED (_("Only files on this computer can be written"));
            var info = file.query_info (FileAttribute.STANDARD_SIZE + "," + FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NONE);
            if (info.get_file_type () == FileType.DIRECTORY) throw new IOError.IS_DIRECTORY (_("This is a folder, not an image file"));
            file_size = info.get_size ();
            var stream = file.read ();
            var head = new uint8[HEAD_SIZE];
            size_t got;
            stream.read_all (head, out got);
            stream.close ();
            head.resize ((int) got);
            kind = detect (head, name);
            image_size = -1;
            problem = null;
            if (file_size == 0) {
                problem = _("The file is empty.");
                return;
            }
            switch (kind) {
                case ImageKind.XZ:
                    int fd = Posix.open (path, Posix.O_RDONLY);
                    if (fd >= 0) {
                        image_size = DecoderBridge.xz_uncompressed_size (fd);
                        Posix.close (fd);
                    }
                    break;
                case ImageKind.ZSTD:
                    image_size = DecoderBridge.zstd_content_size (head);
                    break;
                case ImageKind.GZIP:
                    break;
                default:
                    image_size = (int64) file_size;
                    break;
            }
            if (kind == ImageKind.ZIP || kind == ImageKind.BZIP2) {
                problem = _("Archives must be extracted first. Open the archive and choose the image inside it.");
            } else if (!kind.is_supported ()) {
                problem = _("This compression cannot be read on this computer. Decompress the image first.");
            }
        }
    }

    public class StreamDecoder : Object, Converter {
        private DecoderBridge.Decoder? decoder;
        private int kind;
        private bool ended;

        public StreamDecoder (int kind) throws Error {
            this.kind = kind;
            decoder = DecoderBridge.Decoder.create (kind);
            if (decoder == null) throw new IOError.NOT_SUPPORTED (_("This compression is not supported on this computer"));
        }

        public ConverterResult convert (uint8[] inbuf, uint8[] outbuf, ConverterFlags flags, out size_t bytes_read, out size_t bytes_written) throws Error {
            bytes_read = 0;
            bytes_written = 0;
            if (ended) return ConverterResult.FINISHED;
            bool finish = (flags & ConverterFlags.INPUT_AT_END) != 0;
            size_t consumed, produced;
            int result = decoder.step (inbuf, out consumed, outbuf, out produced, finish);
            bytes_read = consumed;
            bytes_written = produced;
            if (result == DecoderBridge.STEP_ERROR) throw new IOError.INVALID_DATA (_("The image could not be decompressed: %s"), decoder.error ());
            if (result == DecoderBridge.STEP_END) {
                ended = true;
                return ConverterResult.FINISHED;
            }
            if (consumed == 0 && produced == 0) {
                if (finish) throw new IOError.INVALID_DATA (_("The image could not be decompressed: %s"), _("the compressed data ends too early"));
                if (outbuf.length == 0) throw new IOError.NO_SPACE ("output buffer is full");
                throw new IOError.PARTIAL_INPUT ("more input needed");
            }
            return ConverterResult.CONVERTED;
        }

        public void reset () {
            decoder = DecoderBridge.Decoder.create (kind);
            ended = false;
        }
    }

    public class ImageSource : Object {
        public FileInputStream raw { get; private set; }
        public InputStream stream { get; private set; }

        public ImageSource (ImageInfo image) throws Error {
            raw = image.file.read ();
            switch (image.kind) {
                case ImageKind.XZ:
                    stream = new ConverterInputStream (raw, new StreamDecoder (DecoderBridge.KIND_XZ));
                    break;
                case ImageKind.ZSTD:
                    stream = new ConverterInputStream (raw, new StreamDecoder (DecoderBridge.KIND_ZSTD));
                    break;
                case ImageKind.GZIP:
                    stream = new ConverterInputStream (raw, new ZlibDecompressor (ZlibCompressorFormat.GZIP));
                    break;
                default:
                    stream = raw;
                    break;
            }
        }

        public uint64 position () {
            return (uint64) raw.tell ();
        }

        public void close () {
            try {
                stream.close ();
            } catch (Error e) {
            }
        }
    }
}
