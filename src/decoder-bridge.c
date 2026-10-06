#include "decoder-bridge.h"

#include <sys/stat.h>
#include <unistd.h>

#ifdef HAVE_LZMA
#include <lzma.h>
#endif

#ifdef HAVE_ZSTD
#include <zstd.h>
#endif

struct _DwDecoder {
    int kind;
    const char *error;
    gboolean frame_done;
#ifdef HAVE_LZMA
    lzma_stream xz;
#endif
#ifdef HAVE_ZSTD
    ZSTD_DStream *zstd;
#endif
};

gboolean
dw_decoder_available (int kind)
{
#ifdef HAVE_LZMA
    if (kind == DW_KIND_XZ)
        return TRUE;
#endif
#ifdef HAVE_ZSTD
    if (kind == DW_KIND_ZSTD)
        return TRUE;
#endif
    return FALSE;
}

DwDecoder *
dw_decoder_new (int kind)
{
    if (!dw_decoder_available (kind))
        return NULL;
    DwDecoder *decoder = g_new0 (DwDecoder, 1);
    decoder->kind = kind;
#ifdef HAVE_LZMA
    if (kind == DW_KIND_XZ) {
        lzma_stream init = LZMA_STREAM_INIT;
        decoder->xz = init;
        if (lzma_stream_decoder (&decoder->xz, UINT64_MAX, LZMA_CONCATENATED) != LZMA_OK) {
            g_free (decoder);
            return NULL;
        }
    }
#endif
#ifdef HAVE_ZSTD
    if (kind == DW_KIND_ZSTD) {
        decoder->zstd = ZSTD_createDStream ();
        if (decoder->zstd == NULL || ZSTD_isError (ZSTD_initDStream (decoder->zstd))) {
            if (decoder->zstd != NULL)
                ZSTD_freeDStream (decoder->zstd);
            g_free (decoder);
            return NULL;
        }
    }
#endif
    return decoder;
}

#ifdef HAVE_LZMA
static const char *
xz_message (lzma_ret ret)
{
    switch (ret) {
    case LZMA_MEM_ERROR:
    case LZMA_MEMLIMIT_ERROR:
        return "not enough memory to decompress";
    case LZMA_FORMAT_ERROR:
        return "not an xz file";
    case LZMA_OPTIONS_ERROR:
        return "unsupported xz options";
    case LZMA_DATA_ERROR:
        return "the compressed data is corrupt";
    case LZMA_BUF_ERROR:
        return "the compressed data ends too early";
    default:
        return "xz decoding failed";
    }
}
#endif

int
dw_decoder_step (DwDecoder *decoder, const guint8 *input, gsize input_length, gsize *consumed, guint8 *output, gsize output_length, gsize *produced, gboolean finish)
{
    *consumed = 0;
    *produced = 0;
#ifdef HAVE_LZMA
    if (decoder->kind == DW_KIND_XZ) {
        decoder->xz.next_in = input;
        decoder->xz.avail_in = input_length;
        decoder->xz.next_out = output;
        decoder->xz.avail_out = output_length;
        lzma_ret ret = lzma_code (&decoder->xz, finish ? LZMA_FINISH : LZMA_RUN);
        *consumed = input_length - decoder->xz.avail_in;
        *produced = output_length - decoder->xz.avail_out;
        if (ret == LZMA_STREAM_END)
            return DW_STEP_END;
        if (ret == LZMA_OK)
            return DW_STEP_OK;
        if (ret == LZMA_BUF_ERROR && !finish)
            return DW_STEP_OK;
        decoder->error = xz_message (ret);
        return DW_STEP_ERROR;
    }
#endif
#ifdef HAVE_ZSTD
    if (decoder->kind == DW_KIND_ZSTD) {
        ZSTD_inBuffer in = { input, input_length, 0 };
        ZSTD_outBuffer out = { output, output_length, 0 };
        size_t ret = ZSTD_decompressStream (decoder->zstd, &out, &in);
        *consumed = in.pos;
        *produced = out.pos;
        if (ZSTD_isError (ret)) {
            decoder->error = ZSTD_getErrorName (ret);
            return DW_STEP_ERROR;
        }
        if (in.pos > 0 || out.pos > 0)
            decoder->frame_done = ret == 0;
        if (finish && in.pos == input_length) {
            if (decoder->frame_done)
                return DW_STEP_END;
            if (out.pos == 0) {
                decoder->error = "the compressed data ends too early";
                return DW_STEP_ERROR;
            }
        }
        return DW_STEP_OK;
    }
#endif
    decoder->error = "this compression is not supported";
    return DW_STEP_ERROR;
}

const char *
dw_decoder_error (DwDecoder *decoder)
{
    return decoder->error != NULL ? decoder->error : "decoding failed";
}

void
dw_decoder_free (DwDecoder *decoder)
{
    if (decoder == NULL)
        return;
#ifdef HAVE_LZMA
    if (decoder->kind == DW_KIND_XZ)
        lzma_end (&decoder->xz);
#endif
#ifdef HAVE_ZSTD
    if (decoder->kind == DW_KIND_ZSTD && decoder->zstd != NULL)
        ZSTD_freeDStream (decoder->zstd);
#endif
    g_free (decoder);
}

gint64
dw_xz_uncompressed_size (int fd)
{
#ifdef HAVE_LZMA
    struct stat st;
    if (fstat (fd, &st) != 0 || st.st_size < 2 * LZMA_STREAM_HEADER_SIZE)
        return -1;
    guint8 footer[LZMA_STREAM_HEADER_SIZE];
    if (pread (fd, footer, sizeof footer, st.st_size - LZMA_STREAM_HEADER_SIZE) != (ssize_t) sizeof footer)
        return -1;
    lzma_stream_flags flags;
    if (lzma_stream_footer_decode (&flags, footer) != LZMA_OK)
        return -1;
    if (flags.backward_size > (lzma_vli) (st.st_size - 2 * LZMA_STREAM_HEADER_SIZE) || flags.backward_size > 64 * 1024 * 1024)
        return -1;
    gsize length = (gsize) flags.backward_size;
    guint8 *buffer = g_malloc (length);
    gint64 result = -1;
    if (pread (fd, buffer, length, st.st_size - LZMA_STREAM_HEADER_SIZE - length) == (ssize_t) length) {
        lzma_index *index = NULL;
        uint64_t limit = UINT64_MAX;
        size_t pos = 0;
        if (lzma_index_buffer_decode (&index, &limit, NULL, buffer, &pos, length) == LZMA_OK) {
            if (lzma_index_file_size (index) == (lzma_vli) st.st_size)
                result = (gint64) lzma_index_uncompressed_size (index);
            lzma_index_end (index, NULL);
        }
    }
    g_free (buffer);
    return result;
#else
    (void) fd;
    return -1;
#endif
}

gint64
dw_zstd_content_size (const guint8 *head, gsize length)
{
#ifdef HAVE_ZSTD
    unsigned long long size = ZSTD_getFrameContentSize (head, length);
    if (size == ZSTD_CONTENTSIZE_UNKNOWN || size == ZSTD_CONTENTSIZE_ERROR)
        return -1;
    return (gint64) size;
#else
    (void) head;
    (void) length;
    return -1;
#endif
}
