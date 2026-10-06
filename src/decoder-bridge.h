#pragma once

#include <glib.h>

typedef struct _DwDecoder DwDecoder;

enum {
    DW_KIND_XZ = 1,
    DW_KIND_ZSTD = 2
};

enum {
    DW_STEP_ERROR = -1,
    DW_STEP_OK = 0,
    DW_STEP_END = 1
};

gboolean dw_decoder_available (int kind);
DwDecoder *dw_decoder_new (int kind);
int dw_decoder_step (DwDecoder *decoder, const guint8 *input, gsize input_length, gsize *consumed, guint8 *output, gsize output_length, gsize *produced, gboolean finish);
const char *dw_decoder_error (DwDecoder *decoder);
void dw_decoder_free (DwDecoder *decoder);
gint64 dw_xz_uncompressed_size (int fd);
gint64 dw_zstd_content_size (const guint8 *head, gsize length);
