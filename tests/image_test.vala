using Singularity.Apps.DriveWriter;

const int PAYLOAD = 300000;

uint8[] payload (int n) {
    var data = new uint8[n];
    for (int i = 0; i < n; i++) data[i] = (uint8) ((i * 7 + i / 251) & 0xff);
    return data;
}

string fixture (string name) {
    return Path.build_filename (Environment.get_variable ("DRIVEWRITER_FIXTURES"), name);
}

string temp_path (string name) {
    return Path.build_filename (Environment.get_tmp_dir (), "drivewriter-%d-%s".printf (Random.int_range (0, 1000000), name));
}

uint8[] read_stream (InputStream s) throws Error {
    var out_s = new MemoryOutputStream.resizable ();
    out_s.splice (s, OutputStreamSpliceFlags.CLOSE_TARGET);
    var bytes = out_s.steal_as_bytes ();
    return bytes.get_data ().copy ();
}

bool same (uint8[] a, uint8[] b) {
    if (a.length != b.length) return false;
    return Memory.cmp (a, b, a.length) == 0;
}

void test_detect () {
    var head = new uint8[ImageInfo.HEAD_SIZE];
    assert (ImageInfo.detect (head, "x.img") == ImageKind.RAW);
    assert (ImageInfo.detect (head, "x.dat") == ImageKind.UNKNOWN);
    head[510] = 0x55;
    head[511] = 0xAA;
    assert (ImageInfo.detect (head, "x.dat") == ImageKind.DISK);
    uint8[] cd = { 'C', 'D', '0', '0', '1' };
    for (int i = 0; i < 5; i++) head[0x8001 + i] = cd[i];
    assert (ImageInfo.detect (head, "hybrid.iso") == ImageKind.ISO);
    var gpt = new uint8[1024];
    uint8[] sig = { 'E', 'F', 'I', ' ', 'P', 'A', 'R', 'T' };
    for (int i = 0; i < 8; i++) gpt[512 + i] = sig[i];
    assert (ImageInfo.detect (gpt, "disk") == ImageKind.DISK);
    assert (ImageInfo.detect ({ 0xFD, '7', 'z', 'X', 'Z', 0x00, 1 }, "a.iso") == ImageKind.XZ);
    assert (ImageInfo.detect ({ 0x1F, 0x8B, 8 }, "a") == ImageKind.GZIP);
    assert (ImageInfo.detect ({ 0x28, 0xB5, 0x2F, 0xFD }, "a") == ImageKind.ZSTD);
    assert (ImageInfo.detect ({ 'B', 'Z', 'h', '9' }, "a.img.bz2") == ImageKind.BZIP2);
    assert (ImageInfo.detect ({ 'P', 'K', 3, 4 }, "a.zip") == ImageKind.ZIP);
    assert (ImageInfo.detect ({ 0x1F }, "short.gz") == ImageKind.UNKNOWN);
    assert (ImageInfo.detect ({}, "empty.ISO") == ImageKind.RAW);
    assert (!ImageKind.ZIP.is_supported () && !ImageKind.BZIP2.is_supported ());
    assert (ImageKind.GZIP.is_supported () && ImageKind.RAW.is_supported ());
}

void test_inspect () {
    try {
        var xz = new ImageInfo (File.new_for_path (fixture ("payload.img.xz")));
        xz.inspect ();
        assert (xz.kind == ImageKind.XZ);
        assert (xz.problem == null);
        assert (xz.image_size == PAYLOAD);
        var multi = new ImageInfo (File.new_for_path (fixture ("multi.img.xz")));
        multi.inspect ();
        assert (multi.kind == ImageKind.XZ && multi.image_size == -1);
        var zst = new ImageInfo (File.new_for_path (fixture ("payload.img.zst")));
        zst.inspect ();
        assert (zst.kind == ImageKind.ZSTD && zst.image_size == PAYLOAD);
        var nosize = new ImageInfo (File.new_for_path (fixture ("payload-nosize.img.zst")));
        nosize.inspect ();
        assert (nosize.image_size == -1);
        assert (nosize.fits (10) == Fit.UNKNOWN);
        var gz = new ImageInfo (File.new_for_path (fixture ("payload.img.gz")));
        gz.inspect ();
        assert (gz.kind == ImageKind.GZIP && gz.image_size == -1);

        string raw_path = temp_path ("raw.img");
        FileUtils.set_data (raw_path, payload (4096));
        var raw = new ImageInfo (File.new_for_path (raw_path));
        raw.inspect ();
        assert (raw.kind == ImageKind.RAW && raw.image_size == 4096 && raw.file_size == 4096);
        assert (raw.fits (4096) == Fit.FITS && raw.fits (4095) == Fit.TOO_LARGE);
        FileUtils.remove (raw_path);

        string empty_path = temp_path ("empty.iso");
        FileUtils.set_data (empty_path, new uint8[0]);
        var empty = new ImageInfo (File.new_for_path (empty_path));
        empty.inspect ();
        assert (empty.problem != null);
        FileUtils.remove (empty_path);

        string zip_path = temp_path ("image.zip");
        FileUtils.set_data (zip_path, new uint8[] { 'P', 'K', 3, 4, 0, 0 });
        var zip = new ImageInfo (File.new_for_path (zip_path));
        zip.inspect ();
        assert (zip.kind == ImageKind.ZIP && zip.problem != null);
        FileUtils.remove (zip_path);
    } catch (Error e) {
        error ("%s", e.message);
    }
}

void test_size_checks () {
    assert (ImageInfo.check_fit (-1, 1000) == Fit.UNKNOWN);
    assert (ImageInfo.check_fit (0, 0) == Fit.FITS);
    assert (ImageInfo.check_fit (1000, 1000) == Fit.FITS);
    assert (ImageInfo.check_fit (1001, 1000) == Fit.TOO_LARGE);
    int64 four_gb = 4LL * 1024 * 1024 * 1024;
    assert (ImageInfo.check_fit (four_gb, 4000000000ULL) == Fit.TOO_LARGE);
    assert (ImageInfo.check_fit (four_gb, 8000000000ULL) == Fit.FITS);
}

void test_decompress () {
    var expected = payload (PAYLOAD);
    foreach (string name in new string[] { "payload.img.xz", "multi.img.xz", "payload.img.gz", "payload.img.zst", "payload-nosize.img.zst" }) {
        try {
            var info = new ImageInfo (File.new_for_path (fixture (name)));
            info.inspect ();
            var source = new ImageSource (info);
            var data = read_stream (source.stream);
            assert (same (data, expected));
            assert (source.position () == info.file_size);
        } catch (Error e) {
            error ("%s: %s", name, e.message);
        }
    }
}

void test_truncated () {
    foreach (string name in new string[] { "truncated.img.xz", "truncated.img.zst" }) {
        try {
            var info = new ImageInfo (File.new_for_path (fixture (name)));
            info.inspect ();
            if (name.has_suffix (".xz")) assert (info.image_size == -1);
            var source = new ImageSource (info);
            read_stream (source.stream);
            assert_not_reached ();
        } catch (Error e) {
            assert (e is IOError.INVALID_DATA);
        }
    }
}

void test_copy_and_verify () {
    var data = payload (Copier.BUFFER * 2 + 12345);
    string target = temp_path ("target.bin");
    try {
        int fd = Posix.open (target, Posix.O_RDWR | Posix.O_CREAT | Posix.O_TRUNC, 0600);
        assert (fd >= 0);
        uint64 written;
        int ticks = 0;
        string hash = Copier.write_stream (new MemoryInputStream.from_data (data), fd, null, (n) => ticks++, out written);
        assert (written == data.length);
        assert (ticks == 3);
        assert (hash == Checksum.compute_for_data (ChecksumType.SHA256, data));
        Copier.verify (fd, hash, written, null, null);
        Posix.close (fd);

        uint8[] on_disk;
        FileUtils.get_data (target, out on_disk);
        assert (same (on_disk, data));

        on_disk[Copier.BUFFER + 7] ^= 0x40;
        FileUtils.set_data (target, on_disk);
        fd = Posix.open (target, Posix.O_RDONLY);
        try {
            Copier.verify (fd, hash, written, null, null);
            assert_not_reached ();
        } catch (Error e) {
            assert (e is WriteError.MISMATCH);
        }
        try {
            Copier.verify (fd, hash, written + 10, null, null);
            assert_not_reached ();
        } catch (Error e) {
            assert (e is WriteError.SHORT_READ);
        }
        Posix.close (fd);
    } catch (Error e) {
        error ("%s", e.message);
    }
    FileUtils.remove (target);
}

void test_compressed_to_target () {
    string target = temp_path ("zst-target.bin");
    try {
        var info = new ImageInfo (File.new_for_path (fixture ("payload.img.zst")));
        info.inspect ();
        var source = new ImageSource (info);
        int fd = Posix.open (target, Posix.O_RDWR | Posix.O_CREAT | Posix.O_TRUNC, 0600);
        uint64 written;
        string hash = Copier.write_stream (source.stream, fd, null, null, out written);
        assert (written == PAYLOAD);
        Copier.verify (fd, hash, written, null, null);
        Posix.close (fd);
    } catch (Error e) {
        error ("%s", e.message);
    }
    FileUtils.remove (target);
}

void test_no_space_and_cancel () {
    int fd = Posix.open ("/dev/full", Posix.O_WRONLY);
    if (fd >= 0) {
        try {
            uint64 written;
            Copier.write_stream (new MemoryInputStream.from_data (payload (1000)), fd, null, null, out written);
            assert_not_reached ();
        } catch (Error e) {
            assert (e is WriteError.NO_SPACE);
        }
        Posix.close (fd);
    }
    var cancel = new Cancellable ();
    cancel.cancel ();
    string target = temp_path ("cancel.bin");
    fd = Posix.open (target, Posix.O_RDWR | Posix.O_CREAT | Posix.O_TRUNC, 0600);
    try {
        uint64 written;
        Copier.write_stream (new MemoryInputStream.from_data (payload (1000)), fd, cancel, null, out written);
        assert_not_reached ();
    } catch (Error e) {
        assert (e is IOError.CANCELLED);
    }
    Posix.close (fd);
    FileUtils.remove (target);
}

void test_rate () {
    var meter = new RateMeter ();
    assert (meter.rate () == 0);
    meter.add (0, 0);
    meter.add (1000000, 10000000);
    assert (Math.fabs (meter.rate () - 10000000) < 1);
    meter.add (9000000, 90000000);
    assert (Math.fabs (meter.rate () - 10000000) < 1);
    assert (RateMeter.seconds_left (50, 100, 10) == 5);
    assert (RateMeter.seconds_left (50, 100, 0) == -1);
    assert (RateMeter.seconds_left (100, 100, 5) == -1);
    assert (Format.time_left (-1) == "");
    assert (Format.time_left (30) == "less than a minute left");
    assert (Format.time_left (61) == "2 minutes left");
    assert (Format.time_left (3600) == "1 hour left");
    assert (Format.time_left (3900) == "1 h 5 min left");
}

void test_drive_filter () {
    DriveTraits usb = { false, false, "usb", false, 16000000000ULL, false, false };
    assert (DriveFilter.accept (usb));
    DriveTraits card = { false, true, "sdio", false, 32000000000ULL, false, false };
    assert (DriveFilter.accept (card));
    DriveTraits internal_disk = { false, false, "", false, 512000000000ULL, false, false };
    assert (!DriveFilter.accept (internal_disk));
    DriveTraits empty_reader = { true, true, "usb", false, 0, false, false };
    assert (!DriveFilter.accept (empty_reader));
    DriveTraits optical = { true, true, "usb", true, 700000000, false, false };
    assert (!DriveFilter.accept (optical));
    DriveTraits live_stick = { true, false, "usb", false, 16000000000ULL, false, true };
    assert (!DriveFilter.accept (live_stick));
    assert (DriveFilter.is_system_mount ("/") && DriveFilter.is_system_mount ("/boot/efi/"));
    assert (!DriveFilter.is_system_mount ("/run/media/me/STICK"));
}

int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "C");
    Test.init (ref args);
    Test.add_func ("/drivewriter/detect", test_detect);
    Test.add_func ("/drivewriter/inspect", test_inspect);
    Test.add_func ("/drivewriter/size-checks", test_size_checks);
    Test.add_func ("/drivewriter/decompress", test_decompress);
    Test.add_func ("/drivewriter/truncated", test_truncated);
    Test.add_func ("/drivewriter/copy-verify", test_copy_and_verify);
    Test.add_func ("/drivewriter/compressed-target", test_compressed_to_target);
    Test.add_func ("/drivewriter/no-space-cancel", test_no_space_and_cancel);
    Test.add_func ("/drivewriter/rate", test_rate);
    Test.add_func ("/drivewriter/drive-filter", test_drive_filter);
    return Test.run ();
}
