/*
 * Narrow C ABI between papria-format-core and vendored libmobi.
 *
 * This adapter is part of Papria and is Apache-2.0 licensed. libmobi itself
 * remains an unmodified LGPL-3.0-or-later dependency under vendor/libmobi.
 */
#include "libmobi_shim.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mobi.h"

enum {
    PAPRIA_MOBI_MAX_TITLE_BYTES = 4096,
};

static void reset_document(PapriaMobiDocument *document) {
    if (document != NULL) {
        memset(document, 0, sizeof(*document));
    }
}

void papria_mobi_document_free(PapriaMobiDocument *document) {
    size_t index;
    if (document == NULL) {
        return;
    }
    free(document->markup);
    free(document->title);
    for (index = 0; index < document->image_count; index++) {
        free(document->images[index].bytes);
    }
    free(document->images);
    reset_document(document);
}

static bool append_size(size_t *total, size_t addition, size_t maximum) {
    if (addition > maximum || *total > maximum - addition) {
        return false;
    }
    *total += addition;
    return true;
}

static PapriaMobiStatus copy_markup(const MOBIRawml *rawml,
                                   size_t maximum,
                                   PapriaMobiDocument *out) {
    const MOBIPart *part;
    size_t total = 0;
    size_t parts = 0;
    uint8_t *cursor;

    for (part = rawml->markup; part != NULL; part = part->next) {
        if (part->type != T_HTML || part->data == NULL || part->size == 0) {
            continue;
        }
        if (parts > 0 && !append_size(&total, 1, maximum)) {
            return PAPRIA_MOBI_OUTPUT_TOO_LARGE;
        }
        if (!append_size(&total, part->size, maximum)) {
            return PAPRIA_MOBI_OUTPUT_TOO_LARGE;
        }
        parts++;
    }
    if (parts == 0 || total == 0) {
        return PAPRIA_MOBI_INVALID_CONTAINER;
    }
    out->markup = malloc(total);
    if (out->markup == NULL) {
        return PAPRIA_MOBI_ALLOCATION_FAILED;
    }
    cursor = out->markup;
    for (part = rawml->markup; part != NULL; part = part->next) {
        if (part->type != T_HTML || part->data == NULL || part->size == 0) {
            continue;
        }
        if (cursor != out->markup) {
            *cursor++ = '\n';
        }
        memcpy(cursor, part->data, part->size);
        cursor += part->size;
    }
    out->markup_length = total;
    return PAPRIA_MOBI_OK;
}

static bool is_supported_image(const MOBIPart *part) {
    return part->data != NULL && part->size > 0 &&
           (part->type == T_JPG || part->type == T_GIF ||
            part->type == T_PNG || part->type == T_BMP);
}

static PapriaMobiStatus copy_images(const MOBIRawml *rawml,
                                   size_t maximum_bytes,
                                   size_t maximum_count,
                                   PapriaMobiDocument *out) {
    const MOBIPart *part;
    size_t count = 0;
    size_t total = 0;
    size_t index = 0;

    for (part = rawml->resources; part != NULL; part = part->next) {
        if (!is_supported_image(part)) {
            continue;
        }
        if (count == maximum_count || !append_size(&total, part->size, maximum_bytes)) {
            return PAPRIA_MOBI_OUTPUT_TOO_LARGE;
        }
        count++;
    }
    if (count == 0) {
        return PAPRIA_MOBI_OK;
    }
    if (count > SIZE_MAX / sizeof(*out->images)) {
        return PAPRIA_MOBI_OUTPUT_TOO_LARGE;
    }
    out->images = calloc(count, sizeof(*out->images));
    if (out->images == NULL) {
        return PAPRIA_MOBI_ALLOCATION_FAILED;
    }
    for (part = rawml->resources; part != NULL; part = part->next) {
        if (!is_supported_image(part)) {
            continue;
        }
        out->images[index].bytes = malloc(part->size);
        if (out->images[index].bytes == NULL) {
            return PAPRIA_MOBI_ALLOCATION_FAILED;
        }
        memcpy(out->images[index].bytes, part->data, part->size);
        out->images[index].length = part->size;
        index++;
        /* Keep cleanup safe if a later resource allocation fails. */
        out->image_count = index;
    }
    return PAPRIA_MOBI_OK;
}

static PapriaMobiStatus copy_title(const MOBIData *m, PapriaMobiDocument *out) {
    char *value = mobi_meta_get_title(m);
    size_t length = 0;
    if (value == NULL) {
        return PAPRIA_MOBI_OK;
    }
    while (length <= PAPRIA_MOBI_MAX_TITLE_BYTES && value[length] != '\0') {
        length++;
    }
    if (length > PAPRIA_MOBI_MAX_TITLE_BYTES) {
        free(value);
        return PAPRIA_MOBI_INVALID_CONTAINER;
    }
    if (length > 0) {
        out->title = malloc(length);
        if (out->title == NULL) {
            free(value);
            return PAPRIA_MOBI_ALLOCATION_FAILED;
        }
        memcpy(out->title, value, length);
        out->title_length = length;
    }
    free(value);
    return PAPRIA_MOBI_OK;
}

static PapriaMobiStatus map_load_status(MOBI_RET status) {
    if (status == MOBI_FILE_ENCRYPTED || status == MOBI_DRM_PIDINV ||
        status == MOBI_DRM_KEYNOTFOUND || status == MOBI_DRM_UNSUPPORTED ||
        status == MOBI_DRM_EXPIRED) {
        return PAPRIA_MOBI_ENCRYPTED;
    }
    if (status == MOBI_MALLOC_FAILED) {
        return PAPRIA_MOBI_ALLOCATION_FAILED;
    }
    return PAPRIA_MOBI_INVALID_CONTAINER;
}

PapriaMobiStatus papria_mobi_decode(const uint8_t *input,
                                  size_t input_length,
                                  size_t max_markup_length,
                                  size_t max_image_bytes,
                                  size_t max_image_count,
                                  PapriaMobiDocument *out) {
    FILE *file = NULL;
    MOBIData *mobi = NULL;
    MOBIRawml *rawml = NULL;
    MOBI_RET result;
    PapriaMobiStatus status = PAPRIA_MOBI_INVALID_CONTAINER;

    if (out == NULL || (input == NULL && input_length != 0) ||
        max_markup_length == 0) {
        return PAPRIA_MOBI_INVALID_CONTAINER;
    }
    reset_document(out);

    file = tmpfile();
    if (file == NULL) {
        return PAPRIA_MOBI_IO_FAILED;
    }
    if (input_length > 0 && fwrite(input, 1, input_length, file) != input_length) {
        status = PAPRIA_MOBI_IO_FAILED;
        goto cleanup;
    }
    if (fflush(file) != 0 || fseek(file, 0, SEEK_SET) != 0) {
        status = PAPRIA_MOBI_IO_FAILED;
        goto cleanup;
    }

    mobi = mobi_init();
    if (mobi == NULL) {
        status = PAPRIA_MOBI_ALLOCATION_FAILED;
        goto cleanup;
    }
    result = mobi_load_file(mobi, file);
    if (result != MOBI_SUCCESS) {
        status = map_load_status(result);
        goto cleanup;
    }
    if (mobi_is_encrypted(mobi)) {
        status = PAPRIA_MOBI_ENCRYPTED;
        goto cleanup;
    }

    rawml = mobi_init_rawml(mobi);
    if (rawml == NULL) {
        status = PAPRIA_MOBI_ALLOCATION_FAILED;
        goto cleanup;
    }
    result = mobi_parse_rawml_opt(rawml, mobi, false, false, true);
    if (result != MOBI_SUCCESS) {
        status = map_load_status(result);
        goto cleanup;
    }
    status = copy_markup(rawml, max_markup_length, out);
    if (status != PAPRIA_MOBI_OK) {
        goto cleanup;
    }
    status = copy_title(mobi, out);
    if (status != PAPRIA_MOBI_OK) {
        goto cleanup;
    }
    status = copy_images(rawml, max_image_bytes, max_image_count, out);

cleanup:
    mobi_free_rawml(rawml);
    mobi_free(mobi);
    fclose(file);
    if (status != PAPRIA_MOBI_OK) {
        papria_mobi_document_free(out);
    }
    return status;
}
