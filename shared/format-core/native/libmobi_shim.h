/*
 * Narrow C ABI between papria-format-core and vendored libmobi.
 *
 * This adapter is part of Papria and is Apache-2.0 licensed. libmobi itself
 * remains an unmodified LGPL-3.0-or-later dependency under vendor/libmobi.
 */
#ifndef PAPRIA_LIBMOBI_SHIM_H
#define PAPRIA_LIBMOBI_SHIM_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    PAPRIA_MOBI_OK = 0,
    PAPRIA_MOBI_INVALID_CONTAINER = 1,
    PAPRIA_MOBI_ENCRYPTED = 2,
    PAPRIA_MOBI_OUTPUT_TOO_LARGE = 3,
    PAPRIA_MOBI_ALLOCATION_FAILED = 4,
    PAPRIA_MOBI_IO_FAILED = 5,
} PapriaMobiStatus;

typedef struct {
    uint8_t *bytes;
    size_t length;
} PapriaMobiImage;

typedef struct {
    uint8_t *markup;
    size_t markup_length;
    uint8_t *title;
    size_t title_length;
    PapriaMobiImage *images;
    size_t image_count;
} PapriaMobiDocument;

/*
 * Parse a complete MOBI-family byte stream with libmobi. The input is written
 * only to an anonymous tmpfile() because libmobi exposes FILE*-based loading;
 * no caller-supplied path is accepted or retained. Encrypted input is rejected
 * before raw markup is parsed. On every result, `out` can be passed to
 * papria_mobi_document_free().
 */
PapriaMobiStatus papria_mobi_decode(const uint8_t *input,
                                  size_t input_length,
                                  size_t max_markup_length,
                                  size_t max_image_bytes,
                                  size_t max_image_count,
                                  PapriaMobiDocument *out);

void papria_mobi_document_free(PapriaMobiDocument *document);

#endif
