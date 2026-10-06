using Singularity.Apps.DriveWriter;

const string ISO_HASH = "5f2b4a9c1e0d3b7a6c8e9f0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e";
const string OTHER_HASH = "0000000000000000000000000000000000000000000000000000000000000001";

string temp_dir () {
    try {
        return DirUtils.make_tmp ("drivewriter-sums-XXXXXX");
    } catch (Error e) {
        error (e.message);
    }
}

void put (string dir, string name, string text) {
    try {
        FileUtils.set_contents (Path.build_filename (dir, name), text);
    } catch (Error e) {
        error (e.message);
    }
}

void wipe (string dir) {
    try {
        var d = Dir.open (dir);
        string? n;
        while ((n = d.read_name ()) != null) FileUtils.remove (Path.build_filename (dir, n));
    } catch (Error e) {
    }
    DirUtils.remove (dir);
}

ChecksumList parse (string text) {
    try {
        return ChecksumList.parse (text);
    } catch (ChecksumError e) {
        error ("%s", e.message);
    }
}

void test_clean () {
    assert (ChecksumList.clean_hash ("  " + ISO_HASH.up () + "\n") == ISO_HASH);
    assert (ChecksumList.clean_hash ("sha256:" + ISO_HASH) == ISO_HASH);
    assert (ChecksumList.clean_hash ("SHA-256: " + ISO_HASH) == ISO_HASH);
    assert (ChecksumList.clean_hash (ISO_HASH.substring (1)) == null);
    assert (ChecksumList.clean_hash (ISO_HASH.substring (1) + "g") == null);
    assert (ChecksumList.clean_hash ("md5:" + ISO_HASH) == null);
    string sha512 = string.nfill (128, 'a');
    assert (ChecksumList.clean_hash (sha512) == sha512);
    assert (ChecksumList.kind_for (sha512) == ChecksumType.SHA512);
    assert (ChecksumList.kind_for (ISO_HASH) == ChecksumType.SHA256);
}

void test_formats () {
    var gnu = parse ("# comment\n%s  distro-1.0-amd64.iso\n%s *other.img\n".printf (ISO_HASH, OTHER_HASH));
    assert (gnu.size == 2);
    assert (gnu.lookup ("distro-1.0-amd64.iso") == ISO_HASH);
    assert (gnu.lookup ("other.img") == OTHER_HASH);
    assert (gnu.lookup ("DISTRO-1.0-AMD64.ISO") == ISO_HASH);
    assert (gnu.lookup ("missing.iso") == null);

    var bsd = parse ("# Fedora style\nSHA256 (Fedora-Live-x86_64.iso) = %s\nSHA256 (other.iso) = %s\n".printf (ISO_HASH.up (), OTHER_HASH));
    assert (bsd.lookup ("Fedora-Live-x86_64.iso") == ISO_HASH);

    var signed = parse ("-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\n%s  ./images/sub/distro.iso\n-----BEGIN PGP SIGNATURE-----\niQIzBAEBCAAdFiEE\n-----END PGP SIGNATURE-----\n".printf (ISO_HASH));
    assert (signed.size == 1 && signed.lookup ("distro.iso") == ISO_HASH);

    var bare = parse ("%s\n".printf (ISO_HASH));
    assert (bare.lookup ("anything.iso") == ISO_HASH);
    var sidecar = parse ("%s  \n".printf (ISO_HASH));
    assert (sidecar.lookup ("x.img") == ISO_HASH);
    var windows = parse ("%s *C:\\Downloads\\win.iso\r\n".printf (ISO_HASH));
    assert (windows.lookup ("win.iso") == ISO_HASH);

    try {
        var e = gnu.expected_for ("distro-1.0-amd64.iso", "SHA256SUMS");
        assert (e.hex == ISO_HASH && e.source == "SHA256SUMS" && e.algorithm () == "SHA-256");
        assert (e.matches (ISO_HASH.up ()) && !e.matches (OTHER_HASH));
        gnu.expected_for ("nope.iso", "SHA256SUMS");
        error ("unlisted image accepted");
    } catch (ChecksumError e) {
        assert (e is ChecksumError.NOT_LISTED);
    }
    foreach (string junk in new string[] { "", "hello world", "1234 file.iso", "<html>not a list</html>" }) {
        try {
            ChecksumList.parse (junk);
            error ("junk accepted: %s", junk);
        } catch (ChecksumError e) {
            assert (e is ChecksumError.INVALID);
        }
    }
}

void test_sidecar () {
    string dir = temp_dir ();
    put (dir, "distro.iso", "image bytes");
    var image = File.new_for_path (Path.build_filename (dir, "distro.iso"));
    assert (Sidecar.find (image) == null);

    put (dir, "SHA256SUMS", "%s  unrelated.iso\n".printf (OTHER_HASH));
    assert (Sidecar.find (image) == null);

    put (dir, "Distro-1.0-x86_64-CHECKSUM", "SHA256 (distro.iso) = %s\n".printf (ISO_HASH));
    var found = Sidecar.find (image);
    assert (found != null && found.hex == ISO_HASH && found.source == "Distro-1.0-x86_64-CHECKSUM");

    put (dir, "SHA256SUMS", "%s  unrelated.iso\n%s  distro.iso\n".printf (OTHER_HASH, OTHER_HASH));
    found = Sidecar.find (image);
    assert (found != null && found.hex == OTHER_HASH && found.source == "SHA256SUMS");

    put (dir, "distro.iso.sha256", "%s\n".printf (ISO_HASH));
    found = Sidecar.find (image);
    assert (found != null && found.hex == ISO_HASH && found.source == "distro.iso.sha256");
    wipe (dir);
}

void test_hash () {
    string dir = temp_dir ();
    var data = new uint8[Copier.BUFFER + 12345];
    for (int i = 0; i < data.length; i++) data[i] = (uint8) ((i * 31 + 7) & 0xff);
    string path = Path.build_filename (dir, "payload.img");
    try {
        FileUtils.set_data (path, data);
    } catch (Error e) {
        error (e.message);
    }
    string want = Checksum.compute_for_data (ChecksumType.SHA256, data);
    var loop = new MainLoop ();
    var job = new HashJob ();
    string? got = null;
    job.run.begin (File.new_for_path (path), ChecksumType.SHA256, (o, res) => {
        try {
            got = job.run.end (res);
        } catch (Error e) {
            error (e.message);
        }
        loop.quit ();
    });
    loop.run ();
    assert (got == want);
    assert (job.total == data.length && job.progress () == data.length);

    var stopped = new HashJob ();
    stopped.cancellable.cancel ();
    bool cancelled = false;
    stopped.run.begin (File.new_for_path (path), ChecksumType.SHA256, (o, res) => {
        try {
            stopped.run.end (res);
        } catch (Error e) {
            cancelled = e is IOError.CANCELLED;
        }
        loop.quit ();
    });
    loop.run ();
    assert (cancelled);

    string sha512 = "";
    try {
        sha512 = HashJob.hash_stream (new MemoryInputStream.from_data (data), ChecksumType.SHA512, null, null);
    } catch (Error e) {
        error (e.message);
    }
    assert (sha512 == Checksum.compute_for_data (ChecksumType.SHA512, data));
    FileUtils.remove (path);
    DirUtils.remove (dir);
}

void test_labels () {
    var fat = FileSystemKind.FAT32;
    var exfat = FileSystemKind.EXFAT;
    assert (fat.check_label ("USB DRIVE") == null);
    assert (fat.check_label ("") == null);
    assert (fat.check_label ("TWELVE CHARS") != null);
    assert (fat.check_label ("A.B") != null);
    assert (fat.check_label ("ÜBER") != null);
    assert (fat.normalize_label (" backup ") == "BACKUP");
    assert (exfat.check_label ("Fifteen chars!!") == null);
    assert (exfat.check_label ("Sixteen chars!!!") != null);
    assert (exfat.check_label ("a:b") != null);
    assert (exfat.check_label ("Über Stick") == null);
    assert (exfat.normalize_label (" Photos ") == "Photos");
    assert (fat.udisks_type () == "vfat" && fat.mbr_type () == "0x0c");
    assert (exfat.udisks_type () == "exfat" && exfat.mbr_type () == "0x07");
}

void main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/checksum/clean", test_clean);
    Test.add_func ("/checksum/formats", test_formats);
    Test.add_func ("/checksum/sidecar", test_sidecar);
    Test.add_func ("/checksum/hash", test_hash);
    Test.add_func ("/restore/labels", test_labels);
    Test.run ();
}
