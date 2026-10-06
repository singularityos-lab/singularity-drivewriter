[CCode (cheader_filename = "decoder-bridge.h")]
namespace DecoderBridge {
    [CCode (cname = "DW_KIND_XZ")]
    public const int KIND_XZ;
    [CCode (cname = "DW_KIND_ZSTD")]
    public const int KIND_ZSTD;
    [CCode (cname = "DW_STEP_ERROR")]
    public const int STEP_ERROR;
    [CCode (cname = "DW_STEP_OK")]
    public const int STEP_OK;
    [CCode (cname = "DW_STEP_END")]
    public const int STEP_END;

    [Compact]
    [CCode (cname = "DwDecoder", free_function = "dw_decoder_free")]
    public class Decoder {
        [CCode (cname = "dw_decoder_new")]
        public static Decoder? create (int kind);
        [CCode (cname = "dw_decoder_step")]
        public int step ([CCode (array_length_type = "gsize")] uint8[] input, out size_t consumed, [CCode (array_length_type = "gsize")] uint8[] output, out size_t produced, bool finish);
        [CCode (cname = "dw_decoder_error")]
        public unowned string error ();
    }

    [CCode (cname = "dw_decoder_available")]
    public bool available (int kind);
    [CCode (cname = "dw_xz_uncompressed_size")]
    public int64 xz_uncompressed_size (int fd);
    [CCode (cname = "dw_zstd_content_size")]
    public int64 zstd_content_size ([CCode (array_length_type = "gsize")] uint8[] head);
}
