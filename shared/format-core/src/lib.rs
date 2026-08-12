//! Cross-platform format and content primitives.
//!
//! This crate is deliberately small. It does not render a publication or
//! write extracted archive members; instead it provides the deterministic
//! decisions which must be identical on Android and iOS before a platform
//! reader is invoked. Comic archive enumeration reads only bounded slices from
//! a caller-owned source, validates container metadata, and never receives a
//! host path or extraction destination.

#![allow(clippy::empty_line_after_doc_comments)]

use std::collections::BTreeSet;
use std::fmt;
use std::io::{self, Read};

use sha2::{Digest, Sha256};

uniffi::include_scaffolding!("papria_format_core");

/// Formats accepted by the first client release.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SupportedFormat {
    Epub,
    Kepub,
    Mobi,
    Azw,
    Azw3,
    Fb2,
    Pdf,
    Cbz,
    Cbr,
    Cb7,
    M4b,
    M4a,
    Mp3,
    Opus,
    Ogg,
    Flac,
}

/// The platform reader which should receive a file after import.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ReaderStrategy {
    ReadiumEpub,
    ConvertToEpub,
    ReadiumPdf,
    ComicArchive,
    Audio,
}

/// Errors returned by the DRM-free text conversion boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConversionError {
    InputTooShort,
    InvalidContainer,
    UnsupportedCompression,
    Encrypted,
    InvalidUtf8,
    OutputTooLarge,
    UnsupportedFormat,
}

impl fmt::Display for ConversionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InputTooShort => "input is too short",
            Self::InvalidContainer => "invalid ebook container",
            Self::UnsupportedCompression => "unsupported ebook compression",
            Self::Encrypted => "encrypted ebook is not supported",
            Self::InvalidUtf8 => "ebook text is not valid UTF-8",
            Self::OutputTooLarge => "converted text exceeds the bounded output size",
            Self::UnsupportedFormat => "format has no text conversion boundary",
        })
    }
}

impl std::error::Error for ConversionError {}

/// Maximum text exposed through the conversion API. Platform readers can use
/// the original file for pagination after this bounded preview is displayed.
pub const MAX_CONVERTED_TEXT_BYTES: usize = 32 * 1024 * 1024;
/// Maximum aggregate bytes and record count copied from a MOBI image section.
/// Images are retained only when their magic identifies a format that the
/// platform EPUB readers can display; unknown records are not guessed.
const MAX_CONVERTED_IMAGE_BYTES: usize = 32 * 1024 * 1024;
const MAX_CONVERTED_IMAGE_COUNT: usize = 256;
/// Maximum source size accepted by the bounded text conversion entry points.
/// Platform downloaders should still stream and validate the complete file;
/// this guard prevents a hostile FFI sequence from being handed to a parser
/// with an unbounded input budget.
pub const MAX_CONVERSION_INPUT_BYTES: usize = 256 * 1024 * 1024;

/// Convert an FB2 XML body to a small, deterministic HTML document.
///
/// The function deliberately preserves text and paragraph/title boundaries but
/// does not execute markup, resolve external entities, or load referenced
/// resources. A platform reader may replace this HTML with a richer renderer
/// while retaining the same validated input boundary.
fn convert_fb2_to_html_ref(source: &str) -> Result<String, ConversionError> {
    if source.len() > MAX_CONVERSION_INPUT_BYTES {
        return Err(ConversionError::OutputTooLarge);
    }
    let mut text = String::with_capacity(source.len().min(MAX_CONVERTED_TEXT_BYTES));
    let mut in_tag = false;
    let mut tag = String::new();
    for character in source.chars() {
        if character == '<' {
            in_tag = true;
            tag.clear();
            continue;
        }
        if in_tag {
            if character == '>' {
                in_tag = false;
                let normalized = tag.trim().trim_start_matches('/').to_ascii_lowercase();
                if matches!(
                    normalized.as_str(),
                    "p" | "section" | "title" | "subtitle" | "body" | "empty-line"
                ) {
                    text.push_str("\n\n");
                }
            } else if tag.len() < 64 {
                tag.push(character);
            }
            continue;
        }
        text.push(character);
        if text.len() > MAX_CONVERTED_TEXT_BYTES {
            return Err(ConversionError::OutputTooLarge);
        }
    }
    if in_tag {
        return Err(ConversionError::InvalidContainer);
    }
    let plain = decode_xml_entities(text.trim().to_owned());
    if plain.is_empty() {
        return Err(ConversionError::InvalidContainer);
    }
    let escaped = escape_html(&plain);
    Ok(format!(
        "<article><p>{}</p></article>",
        escaped.replace("\n\n", "</p><p>")
    ))
}

#[derive(Debug, Clone)]
struct MobiImage {
    name: String,
    media_type: &'static str,
    bytes: Vec<u8>,
}

#[repr(C)]
struct LibmobiImage {
    bytes: *const u8,
    length: usize,
}

#[repr(C)]
struct LibmobiDocument {
    markup: *const u8,
    markup_length: usize,
    title: *const u8,
    title_length: usize,
    images: *const LibmobiImage,
    image_count: usize,
}

unsafe extern "C" {
    fn papria_mobi_decode(
        input: *const u8,
        input_length: usize,
        max_markup_length: usize,
        max_image_bytes: usize,
        max_image_count: usize,
        out: *mut LibmobiDocument,
    ) -> std::ffi::c_int;
    fn papria_mobi_document_free(document: *mut LibmobiDocument);
}

const PAPRIA_MOBI_OK: std::ffi::c_int = 0;
const PAPRIA_MOBI_ENCRYPTED: std::ffi::c_int = 2;
const PAPRIA_MOBI_OUTPUT_TOO_LARGE: std::ffi::c_int = 3;

fn copy_libmobi_bytes(pointer: *const u8, length: usize) -> Result<Vec<u8>, ConversionError> {
    if length == 0 {
        return Ok(Vec::new());
    }
    if pointer.is_null() {
        return Err(ConversionError::InvalidContainer);
    }
    // The C shim owns this memory until `papria_mobi_document_free` below. Copy
    // it before that call so libmobi allocation details never escape this crate.
    Ok(unsafe { std::slice::from_raw_parts(pointer, length).to_vec() })
}

/// Decode a DRM-free MOBI-family container through the pinned libmobi C
/// parser. The shim uses only an anonymous controlled temporary file because
/// libmobi's supported loader accepts a `FILE *`; Rust never supplies a path.
/// DRM is rejected before raw markup is reconstructed, and there is no Rust
/// parser fallback for MOBI/AZW/AZW3.
fn extract_mobi_family_content_ref(
    input: &[u8],
) -> Result<(String, String, Vec<MobiImage>), ConversionError> {
    if input.len() > MAX_CONVERSION_INPUT_BYTES {
        return Err(ConversionError::OutputTooLarge);
    }
    let mut document = LibmobiDocument {
        markup: std::ptr::null(),
        markup_length: 0,
        title: std::ptr::null(),
        title_length: 0,
        images: std::ptr::null(),
        image_count: 0,
    };
    let status = unsafe {
        papria_mobi_decode(
            input.as_ptr(),
            input.len(),
            MAX_CONVERTED_TEXT_BYTES,
            MAX_CONVERTED_IMAGE_BYTES,
            MAX_CONVERTED_IMAGE_COUNT,
            &mut document,
        )
    };
    let result = (|| match status {
        PAPRIA_MOBI_OK => {
            let markup = copy_libmobi_bytes(document.markup, document.markup_length)?;
            let text = String::from_utf8(markup).map_err(|_| ConversionError::InvalidUtf8)?;
            if text.is_empty() {
                return Err(ConversionError::InvalidContainer);
            }
            let title =
                String::from_utf8(copy_libmobi_bytes(document.title, document.title_length)?)
                    .map_err(|_| ConversionError::InvalidUtf8)?;
            let raw_images = if document.image_count == 0 {
                &[][..]
            } else if document.images.is_null() {
                return Err(ConversionError::InvalidContainer);
            } else {
                unsafe { std::slice::from_raw_parts(document.images, document.image_count) }
            };
            let mut total_bytes = 0usize;
            let mut images = Vec::with_capacity(raw_images.len());
            for raw_image in raw_images {
                let bytes = copy_libmobi_bytes(raw_image.bytes, raw_image.length)?;
                let Some((media_type, extension)) = mobi_image_type(&bytes) else {
                    continue;
                };
                total_bytes = total_bytes
                    .checked_add(bytes.len())
                    .filter(|value| *value <= MAX_CONVERTED_IMAGE_BYTES)
                    .ok_or(ConversionError::OutputTooLarge)?;
                if images.len() >= MAX_CONVERTED_IMAGE_COUNT {
                    return Err(ConversionError::OutputTooLarge);
                }
                images.push(MobiImage {
                    name: format!("mobi-{:04}.{extension}", images.len()),
                    media_type,
                    bytes,
                });
            }
            Ok((text, title, images))
        }
        PAPRIA_MOBI_ENCRYPTED => Err(ConversionError::Encrypted),
        PAPRIA_MOBI_OUTPUT_TOO_LARGE => Err(ConversionError::OutputTooLarge),
        _ => Err(ConversionError::InvalidContainer),
    })();
    unsafe { papria_mobi_document_free(&mut document) };
    result
}

fn mobi_image_type(bytes: &[u8]) -> Option<(&'static str, &'static str)> {
    if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        Some(("image/jpeg", "jpg"))
    } else if bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]) {
        Some(("image/png", "png"))
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some(("image/gif", "gif"))
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some(("image/webp", "webp"))
    } else if bytes.starts_with(b"BM") {
        Some(("image/bmp", "bmp"))
    } else {
        None
    }
}

/// Convert MOBI HTML into the same safe, text-first representation used by
/// the FB2 adapter. Image tags are replaced in source order with validated
/// internal resource names; scripts, external URLs and unknown markup are
/// never carried into the generated EPUB.
fn mobi_markup_to_html(source: &str, images: &[MobiImage]) -> String {
    let mut value = source.to_owned();
    let mut replacements = Vec::new();
    let mut cursor = 0usize;
    while let Some(relative) = value[cursor..].to_ascii_lowercase().find("<img") {
        let start = cursor + relative;
        let Some(relative_end) = value[start..].find('>') else {
            break;
        };
        let end = start + relative_end;
        let token = format!("__PAPRIA_MOBI_IMAGE_{}__", replacements.len());
        if let Some(image) = images.get(replacements.len()) {
            replacements.push((
                token.clone(),
                format!("<img src=\"Images/{}\" alt=\"\"/>", image.name),
            ));
        }
        value.replace_range(start..=end, &token);
        cursor = start + token.len();
    }
    let mut plain = strip_fb2_markup(&value);
    for (token, replacement) in replacements {
        plain = plain.replace(&token, &replacement);
    }
    escape_html(&plain)
        .replace("&lt;img src=&quot;", "<img src=\"")
        .replace("&quot; alt=&quot;&quot;/&gt;", "\" alt=\"\"/>")
}

/// Convert a supported proprietary/text format into the platform reader's
/// internal HTML representation.
fn convert_to_internal_html_ref(
    format: SupportedFormat,
    input: &[u8],
) -> Result<String, ConversionError> {
    match format {
        SupportedFormat::Fb2 => convert_fb2_to_html_ref(
            std::str::from_utf8(input).map_err(|_| ConversionError::InvalidUtf8)?,
        ),
        SupportedFormat::Mobi | SupportedFormat::Azw | SupportedFormat::Azw3 => {
            let (text, _, images) = extract_mobi_family_content_ref(input)?;
            Ok(format!(
                "<article><p>{}</p></article>",
                mobi_markup_to_html(&text, &images)
            ))
        }
        _ => Err(ConversionError::UnsupportedFormat),
    }
}

/// Build a deterministic, unencrypted EPUB 3 container for converted text.
///
/// The writer intentionally uses stored ZIP members and a bounded number of
/// fixed resources. This keeps the conversion result portable between the
/// Android and iOS adapters without depending on a platform ZIP library, and
/// makes the output easy to hash/cache. MOBI image records are copied into
/// validated `Images/` members and referenced from the sanitized chapter.
fn convert_to_internal_epub_ref(
    format: SupportedFormat,
    input: &[u8],
) -> Result<Vec<u8>, ConversionError> {
    if format == SupportedFormat::Fb2 {
        return convert_fb2_to_epub_ref(input);
    }
    let (html, title, images) = match format {
        SupportedFormat::Mobi | SupportedFormat::Azw | SupportedFormat::Azw3 => {
            let (text, title, images) = extract_mobi_family_content_ref(input)?;
            (mobi_markup_to_html(&text, &images), title, images)
        }
        _ => return Err(ConversionError::UnsupportedFormat),
    };
    let title = if title.trim().is_empty() {
        "Converted Kindle publication".to_owned()
    } else {
        title
    };
    let title = escape_html(&title);
    let chapter = format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>{title}</title></head><body>{html}</body></html>"
    );
    let mut manifest = String::from(
        "<item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
    );
    let mut entries: Vec<(String, Vec<u8>)> = vec![
        ("mimetype".to_owned(), b"application/epub+zip".to_vec()),
        (
            "META-INF/container.xml".to_owned(),
            b"<?xml version=\"1.0\" encoding=\"UTF-8\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".to_vec(),
        ),
        ("OEBPS/chapter.xhtml".to_owned(), chapter.into_bytes()),
    ];
    for (index, image) in images.iter().enumerate() {
        let href = format!("Images/{}", image.name);
        manifest.push_str(&format!(
            "<item id=\"image-{index:04}\" href=\"{href}\" media-type=\"{}\"/>",
            image.media_type
        ));
        entries.push((format!("OEBPS/{href}"), image.bytes.clone()));
    }
    let opf = format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"pub-id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"pub-id\">urn:uuid:papria-converted</dc:identifier><dc:title>{title}</dc:title><dc:language>und</dc:language></metadata><manifest>{manifest}</manifest><spine><itemref idref=\"chapter\"/></spine></package>"
    );
    let nav = format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?><!DOCTYPE html><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>{title}</title></head><body><nav epub:type=\"toc\"><ol><li><a href=\"chapter.xhtml\">{title}</a></li></ol></nav></body></html>"
    );
    entries.push(("OEBPS/content.opf".to_owned(), opf.into_bytes()));
    entries.push(("OEBPS/nav.xhtml".to_owned(), nav.into_bytes()));
    let refs: Vec<(&str, &[u8])> = entries
        .iter()
        .map(|(name, bytes)| (name.as_str(), bytes.as_slice()))
        .collect();
    write_stored_epub(&refs)
}

/// Convert an FB2 publication while retaining its section boundaries and
/// embedded `binary` images. FB2 is XML rather than a ZIP container, so this
/// parser deliberately accepts only the bounded subset needed for a portable
/// EPUB: first `body`, nested `section` elements, text/title tags, and
/// `image` references whose base64 payload is present in the same document.
/// Unknown XML is treated as presentation markup and never executed.
fn convert_fb2_to_epub_ref(input: &[u8]) -> Result<Vec<u8>, ConversionError> {
    if input.len() > MAX_CONVERSION_INPUT_BYTES {
        return Err(ConversionError::OutputTooLarge);
    }
    let source = std::str::from_utf8(input).map_err(|_| ConversionError::InvalidUtf8)?;
    let binaries = extract_fb2_binaries(source)?;
    let body = extract_first_element(source, "body").unwrap_or(source);
    let sections = extract_top_level_sections(body);
    let section_sources = if sections.is_empty() {
        vec![body.to_owned()]
    } else {
        sections
    };
    let mut chapters = Vec::with_capacity(section_sources.len());
    for (index, section) in section_sources.iter().enumerate() {
        let html = fb2_markup_to_html(section, &binaries)?;
        if html.trim().is_empty() {
            continue;
        }
        let title = extract_first_element(section, "title")
            .map(strip_fb2_markup)
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| format!("Chapter {}", index + 1));
        chapters.push((title, html));
    }
    if chapters.is_empty() {
        return Err(ConversionError::InvalidContainer);
    }

    let mut entries: Vec<(String, Vec<u8>)> = Vec::new();
    let mut manifest = String::new();
    let mut spine = String::new();
    let mut nav_items = String::new();
    for (index, (title, html)) in chapters.iter().enumerate() {
        let id = format!("chapter-{:04}", index + 1);
        let href = format!("chapter-{:04}.xhtml", index + 1);
        let chapter = format!(
            "<?xml version=\"1.0\" encoding=\"utf-8\"?><!DOCTYPE html><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>{}</title></head><body>{}</body></html>",
            escape_html(title), html
        );
        entries.push((format!("OEBPS/{}", href), chapter.into_bytes()));
        manifest.push_str(&format!(
            "<item id=\"{}\" href=\"{}\" media-type=\"application/xhtml+xml\"/>",
            id, href
        ));
        spine.push_str(&format!("<itemref idref=\"{}\"/>", id));
        nav_items.push_str(&format!(
            "<li><a href=\"{}\">{}</a></li>",
            href,
            escape_html(title)
        ));
    }
    for binary in binaries.values() {
        let href = format!(
            "Images/{}.{}",
            binary.id,
            media_type_extension(&binary.media_type)
        );
        entries.push((format!("OEBPS/{}", href), binary.bytes.clone()));
        manifest.push_str(&format!(
            "<item id=\"img-{}\" href=\"{}\" media-type=\"{}\"/>",
            binary.id, href, binary.media_type
        ));
    }

    let title = extract_first_element(source, "book-title")
        .map(strip_fb2_markup)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "FB2 publication".to_owned());
    let opf = format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"pub-id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"pub-id\">urn:uuid:papria-fb2</dc:identifier><dc:title>{}</dc:title><dc:language>und</dc:language></metadata><manifest>{}<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/></manifest><spine>{}</spine></package>",
        escape_html(&title), manifest, spine
    );
    let nav = format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?><!DOCTYPE html><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>{}</title></head><body><nav epub:type=\"toc\"><ol>{}</ol></nav></body></html>",
        escape_html(&title), nav_items
    );
    entries.insert(0, ("mimetype".to_owned(), b"application/epub+zip".to_vec()));
    entries.insert(1, ("META-INF/container.xml".to_owned(), b"<?xml version=\"1.0\" encoding=\"UTF-8\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".to_vec()));
    entries.push(("OEBPS/content.opf".to_owned(), opf.into_bytes()));
    entries.push(("OEBPS/nav.xhtml".to_owned(), nav.into_bytes()));
    let refs: Vec<(&str, &[u8])> = entries
        .iter()
        .map(|(name, bytes)| (name.as_str(), bytes.as_slice()))
        .collect();
    write_stored_epub(&refs)
}

#[derive(Debug, Clone)]
struct Fb2Binary {
    id: String,
    media_type: String,
    bytes: Vec<u8>,
}

fn extract_fb2_binaries(
    source: &str,
) -> Result<std::collections::BTreeMap<String, Fb2Binary>, ConversionError> {
    let mut result = std::collections::BTreeMap::new();
    let mut total_bytes = 0usize;
    let mut cursor = 0;
    while let Some(relative) = source[cursor..].find("<binary") {
        let start = cursor + relative;
        let open_end = source[start..]
            .find('>')
            .ok_or(ConversionError::InvalidContainer)?
            + start;
        let close = source[open_end + 1..]
            .find("</binary>")
            .ok_or(ConversionError::InvalidContainer)?
            + open_end
            + 1;
        let attrs = &source[start..=open_end];
        let id = xml_attribute(attrs, "id").ok_or(ConversionError::InvalidContainer)?;
        validate_fb2_binary_id(&id)?;
        if result.contains_key(&id) || result.len() >= MAX_CONVERTED_IMAGE_COUNT {
            return Err(ConversionError::InvalidContainer);
        }
        let media_type = xml_attribute(attrs, "content-type")
            .unwrap_or_else(|| "application/octet-stream".to_owned());
        let bytes = decode_base64(&source.as_bytes()[open_end + 1..close])
            .ok_or(ConversionError::InvalidContainer)?;
        total_bytes = total_bytes
            .checked_add(bytes.len())
            .filter(|value| *value <= MAX_CONVERTED_IMAGE_BYTES)
            .ok_or(ConversionError::OutputTooLarge)?;
        if bytes.len() > MAX_CONVERTED_IMAGE_BYTES {
            return Err(ConversionError::OutputTooLarge);
        }
        result.insert(
            id.clone(),
            Fb2Binary {
                id,
                media_type,
                bytes,
            },
        );
        cursor = close + "</binary>".len();
    }
    Ok(result)
}

/// FB2 binary ids are copied into both an EPUB member path and XML attributes.
/// Keep the accepted subset deliberately narrower than the XML Name grammar so
/// an untrusted id cannot become a path component or an attribute fragment.
fn validate_fb2_binary_id(id: &str) -> Result<(), ConversionError> {
    if id.is_empty()
        || id == "."
        || id == ".."
        || id.len() > MAX_ARCHIVE_PATH_BYTES
        || !id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
    {
        return Err(ConversionError::InvalidContainer);
    }
    validate_archive_entry_path_ref(&format!("Images/{id}.bin"))
        .map_err(|_| ConversionError::InvalidContainer)
}

fn fb2_markup_to_html(
    source: &str,
    binaries: &std::collections::BTreeMap<String, Fb2Binary>,
) -> Result<String, ConversionError> {
    let mut value = source.to_owned();
    let mut replacements = Vec::new();
    let mut cursor = 0;
    while let Some(relative) = value[cursor..].find("<image") {
        let start = cursor + relative;
        let end = value[start..]
            .find('>')
            .ok_or(ConversionError::InvalidContainer)?
            + start;
        let tag = &value[start..=end];
        let href = xml_attribute(tag, "l:href").or_else(|| xml_attribute(tag, "href"));
        let token = format!("__PAPRIA_IMAGE_{}__", replacements.len());
        if let Some(reference) = href
            .as_deref()
            .and_then(|item| item.strip_prefix('#'))
            .and_then(|id| binaries.get(id))
        {
            let replacement = format!(
                "<img src=\"Images/{}.{}\" alt=\"\"/>",
                reference.id,
                media_type_extension(&reference.media_type)
            );
            replacements.push((token.clone(), replacement));
        }
        value.replace_range(start..=end, &token);
        cursor = start + token.len();
    }
    let mut plain = strip_fb2_markup(&value);
    for (token, replacement) in replacements {
        plain = plain.replace(&token, &replacement);
    }
    Ok(escape_html(&plain)
        .replace("&lt;img ", "<img ")
        .replace("/&gt;", "/>"))
}

fn extract_first_element<'a>(source: &'a str, name: &str) -> Option<&'a str> {
    let open = format!("<{}", name);
    let start = source.find(&open)?;
    let open_end = source[start..].find('>')? + start;
    let close = format!("</{}>", name);
    let end = source[open_end + 1..].find(&close)? + open_end + 1;
    Some(&source[open_end + 1..end])
}

fn extract_top_level_sections(source: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut cursor = 0;
    let mut depth = 0usize;
    let mut start = None;
    while cursor < source.len() {
        let next_open = source[cursor..]
            .find("<section")
            .map(|value| cursor + value);
        let next_close = source[cursor..]
            .find("</section>")
            .map(|value| cursor + value);
        let (position, opening) = match (next_open, next_close) {
            (Some(open), Some(close)) if open < close => (open, true),
            (Some(_), Some(close)) => (close, false),
            (Some(open), None) => (open, true),
            (None, Some(close)) => (close, false),
            (None, None) => break,
        };
        if opening {
            if depth == 0 {
                start = Some(position);
            }
            depth += 1;
            cursor = source[position..]
                .find('>')
                .map(|value| position + value + 1)
                .unwrap_or(source.len());
        } else {
            depth = depth.saturating_sub(1);
            cursor = position + "</section>".len();
            if depth == 0 {
                if let Some(begin) = start.take() {
                    result.push(source[begin..cursor].to_owned());
                }
            }
        }
    }
    result
}

fn strip_fb2_markup(source: &str) -> String {
    let mut text = String::with_capacity(source.len().min(MAX_CONVERTED_TEXT_BYTES));
    let mut in_tag = false;
    let mut tag = String::new();
    for character in source.chars() {
        if character == '<' {
            in_tag = true;
            tag.clear();
            continue;
        }
        if in_tag {
            if character == '>' {
                in_tag = false;
                let normalized = tag.trim().trim_start_matches('/').to_ascii_lowercase();
                if matches!(
                    normalized.as_str(),
                    "p" | "section" | "title" | "subtitle" | "body" | "empty-line" | "br"
                ) {
                    text.push_str("\n\n");
                }
            } else if tag.len() < 128 {
                tag.push(character);
            }
            continue;
        }
        text.push(character);
        if text.len() > MAX_CONVERTED_TEXT_BYTES {
            break;
        }
    }
    decode_xml_entities(text.trim().to_owned())
}

fn xml_attribute(tag: &str, name: &str) -> Option<String> {
    let needle = format!("{}=\"", name);
    let start = tag.find(&needle)? + needle.len();
    let end = tag[start..].find('"')? + start;
    Some(tag[start..end].to_owned())
}

fn media_type_extension(media_type: &str) -> &'static str {
    match media_type.to_ascii_lowercase().as_str() {
        "image/jpeg" | "image/jpg" => "jpg",
        "image/png" => "png",
        "image/gif" => "gif",
        "image/webp" => "webp",
        _ => "bin",
    }
}

fn decode_base64(input: &[u8]) -> Option<Vec<u8>> {
    let capacity = input.len().checked_mul(3)?.checked_div(4)?;
    let mut output = Vec::with_capacity(capacity);
    let mut quartet = [0u8; 4];
    let mut count = 0;
    let mut finished = false;
    for byte in input
        .iter()
        .copied()
        .filter(|value| !value.is_ascii_whitespace())
    {
        if finished {
            return None;
        }
        quartet[count] = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' if count >= 2 => 64,
            _ => return None,
        };
        count += 1;
        if count == 4 {
            if quartet[0] >= 64 || quartet[1] >= 64 {
                return None;
            }
            output.push((quartet[0] << 2) | (quartet[1] >> 4));
            match (quartet[2], quartet[3]) {
                (64, 64) => finished = true,
                (_, 64) => {
                    if quartet[2] >= 64 {
                        return None;
                    }
                    output.push((quartet[1] << 4) | (quartet[2] >> 2));
                    finished = true;
                }
                (64, _) => return None,
                (third, fourth) => {
                    output.push((quartet[1] << 4) | (third >> 2));
                    output.push((third << 6) | fourth);
                }
            }
            count = 0;
        }
    }
    if count == 0 {
        Some(output)
    } else {
        None
    }
}

/// UniFFI-owned argument wrapper for the bounded FB2 conversion boundary.
pub fn convert_fb2_to_html(source: String) -> Result<String, ConversionError> {
    convert_fb2_to_html_ref(&source)
}

/// UniFFI-owned argument wrapper for the internal HTML conversion policy.
pub fn convert_to_internal_html(
    format: SupportedFormat,
    input: Vec<u8>,
) -> Result<String, ConversionError> {
    convert_to_internal_html_ref(format, &input)
}

/// UniFFI-owned argument wrapper for deterministic converted EPUB output.
pub fn convert_to_internal_epub(
    format: SupportedFormat,
    input: Vec<u8>,
) -> Result<Vec<u8>, ConversionError> {
    convert_to_internal_epub_ref(format, &input)
}

fn write_stored_epub(entries: &[(&str, &[u8])]) -> Result<Vec<u8>, ConversionError> {
    const LOCAL_HEADER: usize = 30;
    const CENTRAL_HEADER: usize = 46;
    const END_HEADER: usize = 22;
    let total_payload = entries.iter().try_fold(0usize, |total, (name, bytes)| {
        total
            .checked_add(LOCAL_HEADER + name.len() + bytes.len() + CENTRAL_HEADER + name.len())
            .ok_or(ConversionError::OutputTooLarge)
    })?;
    let mut output = Vec::with_capacity(total_payload + END_HEADER);
    let mut central = Vec::new();
    for (name, bytes) in entries {
        if name.len() > u16::MAX as usize || bytes.len() > u32::MAX as usize {
            return Err(ConversionError::OutputTooLarge);
        }
        let offset = output.len();
        let crc = crc32(bytes);
        output.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        output.extend_from_slice(&20u16.to_le_bytes());
        output.extend_from_slice(&0u16.to_le_bytes());
        output.extend_from_slice(&0u16.to_le_bytes());
        output.extend_from_slice(&0u16.to_le_bytes());
        output.extend_from_slice(&0u16.to_le_bytes());
        output.extend_from_slice(&crc.to_le_bytes());
        output.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
        output.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
        output.extend_from_slice(&(name.len() as u16).to_le_bytes());
        output.extend_from_slice(&0u16.to_le_bytes());
        output.extend_from_slice(name.as_bytes());
        output.extend_from_slice(bytes);

        central.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
        central.extend_from_slice(&20u16.to_le_bytes());
        central.extend_from_slice(&20u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&crc.to_le_bytes());
        central.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
        central.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
        central.extend_from_slice(&(name.len() as u16).to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u32.to_le_bytes());
        central.extend_from_slice(&(offset as u32).to_le_bytes());
        central.extend_from_slice(name.as_bytes());
    }
    let central_offset = output.len();
    output.extend_from_slice(&central);
    if entries.len() > u16::MAX as usize
        || central.len() > u32::MAX as usize
        || central_offset > u32::MAX as usize
    {
        return Err(ConversionError::OutputTooLarge);
    }
    output.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    output.extend_from_slice(&0u16.to_le_bytes());
    output.extend_from_slice(&0u16.to_le_bytes());
    output.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    output.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    output.extend_from_slice(&(central.len() as u32).to_le_bytes());
    output.extend_from_slice(&(central_offset as u32).to_le_bytes());
    output.extend_from_slice(&0u16.to_le_bytes());
    if output.len() > MAX_CONVERTED_TEXT_BYTES * 2 {
        return Err(ConversionError::OutputTooLarge);
    }
    Ok(output)
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for byte in bytes {
        crc ^= *byte as u32;
        for _ in 0..8 {
            crc = if crc & 1 == 1 {
                (crc >> 1) ^ 0xedb8_8320
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

fn decode_xml_entities(mut value: String) -> String {
    for (source, target) in [
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&apos;", "'"),
    ] {
        value = value.replace(source, target);
    }
    value
}

fn escape_html(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// Container signatures understood by the safety boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ArchiveKind {
    Zip,
    Rar,
    SevenZip,
    Unknown,
}

impl SupportedFormat {
    /// Parse one extension without compatibility aliases.
    pub fn from_extension(extension: &str) -> Option<Self> {
        let trimmed = extension.trim();
        let normalized = trimmed
            .strip_prefix('.')
            .unwrap_or(trimmed)
            .to_ascii_lowercase();
        Some(match normalized.as_str() {
            "epub" => Self::Epub,
            "kepub" => Self::Kepub,
            "mobi" => Self::Mobi,
            "azw" => Self::Azw,
            "azw3" => Self::Azw3,
            "fb2" => Self::Fb2,
            "pdf" => Self::Pdf,
            "cbz" => Self::Cbz,
            "cbr" => Self::Cbr,
            "cb7" => Self::Cb7,
            "m4b" => Self::M4b,
            "m4a" => Self::M4a,
            "mp3" => Self::Mp3,
            "opus" => Self::Opus,
            "ogg" => Self::Ogg,
            "flac" => Self::Flac,
            _ => return None,
        })
    }

    pub fn strategy(self) -> ReaderStrategy {
        match self {
            Self::Epub | Self::Kepub => ReaderStrategy::ReadiumEpub,
            Self::Mobi | Self::Azw | Self::Azw3 | Self::Fb2 => ReaderStrategy::ConvertToEpub,
            Self::Pdf => ReaderStrategy::ReadiumPdf,
            Self::Cbz | Self::Cbr | Self::Cb7 => ReaderStrategy::ComicArchive,
            Self::M4b | Self::M4a | Self::Mp3 | Self::Opus | Self::Ogg | Self::Flac => {
                ReaderStrategy::Audio
            }
        }
    }

    pub fn is_audio(self) -> bool {
        matches!(
            self,
            Self::M4b | Self::M4a | Self::Mp3 | Self::Opus | Self::Ogg | Self::Flac
        )
    }

    pub fn archive_kind(self) -> Option<ArchiveKind> {
        match self {
            Self::Cbz => Some(ArchiveKind::Zip),
            Self::Cbr => Some(ArchiveKind::Rar),
            Self::Cb7 => Some(ArchiveKind::SevenZip),
            _ => None,
        }
    }
}

/// FFI-friendly free-function form of [`SupportedFormat::strategy`].
pub fn reader_strategy(format: SupportedFormat) -> ReaderStrategy {
    format.strategy()
}

/// Return the format represented by the final extension in a filename.
fn format_from_filename_ref(filename: &str) -> Option<SupportedFormat> {
    filename
        .rsplit_once('.')
        .and_then(|(_, extension)| SupportedFormat::from_extension(extension))
}

/// Detect a format using both its extension and a small, bounded header.
///
/// For containers whose extension implies an archive, a mismatching magic
/// signature is rejected.  This prevents feeding a renamed executable or a
/// malformed file to an archive reader.  Text and proprietary formats still
/// use the explicit extension because their complete parser belongs to the
/// platform adapter.
fn detect_format_ref(filename: &str, header: &[u8]) -> Option<SupportedFormat> {
    let format = format_from_filename_ref(filename)?;
    match format {
        SupportedFormat::Epub | SupportedFormat::Kepub | SupportedFormat::Cbz => {
            (detect_archive_kind_ref(header) == ArchiveKind::Zip).then_some(format)
        }
        SupportedFormat::Cbr => {
            (detect_archive_kind_ref(header) == ArchiveKind::Rar).then_some(format)
        }
        SupportedFormat::Cb7 => {
            (detect_archive_kind_ref(header) == ArchiveKind::SevenZip).then_some(format)
        }
        SupportedFormat::Pdf => header.starts_with(b"%PDF-").then_some(format),
        _ => Some(format),
    }
}

/// Map a filename extension to an archive kind, if it is a comic archive.
fn archive_kind_from_filename_ref(filename: &str) -> Option<ArchiveKind> {
    format_from_filename_ref(filename).and_then(SupportedFormat::archive_kind)
}

/// Map a raw extension to an archive kind, if it is a comic archive.
fn archive_kind_from_extension_ref(extension: &str) -> Option<ArchiveKind> {
    SupportedFormat::from_extension(extension).and_then(SupportedFormat::archive_kind)
}

/// FFI-friendly free-function form of [`SupportedFormat::archive_kind`].
pub fn archive_kind_from_format(format: SupportedFormat) -> Option<ArchiveKind> {
    format.archive_kind()
}

/// Inspect only the bounded signature at the beginning of an archive.
fn detect_archive_kind_ref(bytes: &[u8]) -> ArchiveKind {
    if bytes.starts_with(b"PK\x03\x04")
        || bytes.starts_with(b"PK\x05\x06")
        || bytes.starts_with(b"PK\x07\x08")
    {
        ArchiveKind::Zip
    } else if bytes.starts_with(b"Rar!\x1a\x07\x00") || bytes.starts_with(b"Rar!\x1a\x07\x01\x00") {
        ArchiveKind::Rar
    } else if bytes.starts_with(b"7z\xbc\xaf\x27\x1c") {
        ArchiveKind::SevenZip
    } else {
        ArchiveKind::Unknown
    }
}

pub fn format_from_filename(filename: String) -> Option<SupportedFormat> {
    format_from_filename_ref(&filename)
}

pub fn detect_format(filename: String, header: Vec<u8>) -> Option<SupportedFormat> {
    detect_format_ref(&filename, &header)
}

pub fn archive_kind_from_filename(filename: String) -> Option<ArchiveKind> {
    archive_kind_from_filename_ref(&filename)
}

pub fn archive_kind_from_extension(extension: String) -> Option<ArchiveKind> {
    archive_kind_from_extension_ref(&extension)
}

pub fn detect_archive_kind(bytes: Vec<u8>) -> ArchiveKind {
    detect_archive_kind_ref(&bytes)
}

/// SHA-256 of an in-memory byte slice, encoded as lower-case hexadecimal.
fn sha256_hex_ref(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    hex_encode(&digest)
}

pub fn sha256_hex(bytes: Vec<u8>) -> String {
    sha256_hex_ref(&bytes)
}

/// Hash a stream without reading the complete file into memory.
pub fn sha256_reader<R: Read>(reader: &mut R) -> io::Result<String> {
    let mut hasher = ContentHasher::new();
    let mut buffer = [0_u8; 128 * 1024];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher.finalize_hex())
}

/// A reusable incremental SHA-256 calculator exposed to generated bindings.
#[derive(Clone)]
pub struct ContentHasher {
    state: Sha256,
}

impl fmt::Debug for ContentHasher {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ContentHasher { state: <private> }")
    }
}

impl Default for ContentHasher {
    fn default() -> Self {
        Self::new()
    }
}

impl ContentHasher {
    pub fn new() -> Self {
        Self {
            state: Sha256::new(),
        }
    }

    pub fn update(&mut self, bytes: &[u8]) {
        self.state.update(bytes);
    }

    /// Finalization is non-consuming, so callers may ask for a checkpoint and
    /// continue feeding bytes afterwards.
    pub fn finalize_hex(&self) -> String {
        let digest = self.state.clone().finalize();
        hex_encode(&digest)
    }

    pub fn reset(&mut self) {
        self.state = Sha256::new();
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

/// Keep cache key construction deterministic.  Validation of a server hash
/// remains the caller's responsibility because older BookOrbit records may
/// use a non-SHA identifier while the migration is in progress.
fn converter_cache_key_ref(source_sha256: &str, converter_version: &str) -> String {
    format!("{source_sha256}:{converter_version}")
}

pub fn converter_cache_key(source_sha256: String, converter_version: String) -> String {
    converter_cache_key_ref(&source_sha256, &converter_version)
}

/// Maximum UTF-8 bytes accepted for a local display filename.
pub const MAX_FILENAME_BYTES: usize = 255;
/// Maximum UTF-8 bytes accepted for an archive member path.
pub const MAX_ARCHIVE_PATH_BYTES: usize = 4096;

/// Errors returned when an uploaded/display filename is not safe as-is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FilenameSafetyError {
    Empty,
    PathSeparator,
    Traversal,
    ControlCharacter,
    ReservedCharacter,
    ReservedDeviceName,
    TooLong,
}

impl fmt::Display for FilenameSafetyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Empty => "filename is empty",
            Self::PathSeparator => "filename contains a path separator",
            Self::Traversal => "filename contains a traversal component",
            Self::ControlCharacter => "filename contains a control character",
            Self::ReservedCharacter => "filename contains a reserved character",
            Self::ReservedDeviceName => "filename is a reserved device name",
            Self::TooLong => "filename exceeds the UTF-8 byte limit",
        })
    }
}

impl std::error::Error for FilenameSafetyError {}

/// Check that a user-supplied display/storage filename is a single safe name.
fn validate_filename_ref(filename: &str) -> Result<(), FilenameSafetyError> {
    if filename.is_empty() || filename == "." || filename == ".." {
        return Err(FilenameSafetyError::Empty);
    }
    if filename.len() > MAX_FILENAME_BYTES {
        return Err(FilenameSafetyError::TooLong);
    }
    if filename.contains('/') || filename.contains('\\') {
        return Err(FilenameSafetyError::PathSeparator);
    }
    // Windows treats trailing dots/spaces as equivalent to the trimmed name;
    // rejecting them keeps the validated name and the platform's filesystem
    // identity one-to-one instead of allowing a collision with sanitization.
    if filename.ends_with([' ', '.']) {
        return Err(FilenameSafetyError::ReservedCharacter);
    }
    if filename.split('.').any(|part| part == "..") {
        return Err(FilenameSafetyError::Traversal);
    }
    if filename.chars().any(char::is_control) {
        return Err(FilenameSafetyError::ControlCharacter);
    }
    if filename.chars().any(is_reserved_filename_character) {
        return Err(FilenameSafetyError::ReservedCharacter);
    }
    if is_reserved_device_name(filename) {
        return Err(FilenameSafetyError::ReservedDeviceName);
    }
    Ok(())
}

fn is_reserved_filename_character(character: char) -> bool {
    matches!(character, '<' | '>' | ':' | '"' | '|' | '?' | '*')
}

fn is_reserved_device_name(filename: &str) -> bool {
    let stem = filename.split('.').next().unwrap_or_default();
    matches!(
        stem.to_ascii_uppercase().as_str(),
        "CON"
            | "PRN"
            | "AUX"
            | "NUL"
            | "COM1"
            | "COM2"
            | "COM3"
            | "COM4"
            | "COM5"
            | "COM6"
            | "COM7"
            | "COM8"
            | "COM9"
            | "LPT1"
            | "LPT2"
            | "LPT3"
            | "LPT4"
            | "LPT5"
            | "LPT6"
            | "LPT7"
            | "LPT8"
            | "LPT9"
    )
}

/// Produce a deterministic display name for an untrusted upload name.
///
/// This helper intentionally strips directory components first and then
/// replaces unsafe characters.  Callers which need fail-closed behavior must
/// use [`validate_filename`] instead of silently sanitizing a name.
fn sanitize_filename_ref(filename: &str) -> String {
    let basename = filename.rsplit(['/', '\\']).next().unwrap_or(filename);
    let mut output = String::with_capacity(basename.len().min(MAX_FILENAME_BYTES));
    for character in basename.chars() {
        let replacement = if character.is_control() || is_reserved_filename_character(character) {
            '_'
        } else {
            character
        };
        output.push(replacement);
    }
    let trimmed = output.trim_matches([' ', '.']).to_owned();
    let mut output = if trimmed.is_empty() || trimmed == "." || trimmed == ".." {
        "untitled".to_owned()
    } else if is_reserved_device_name(&trimmed) {
        format!("_{trimmed}")
    } else {
        trimmed
    };
    truncate_utf8(&mut output, MAX_FILENAME_BYTES);
    if output.is_empty() {
        "untitled".to_owned()
    } else {
        output
    }
}

pub fn validate_filename(filename: String) -> Result<(), FilenameSafetyError> {
    validate_filename_ref(&filename)
}

pub fn sanitize_filename(filename: String) -> String {
    sanitize_filename_ref(&filename)
}

fn truncate_utf8(value: &mut String, max_bytes: usize) {
    if value.len() <= max_bytes {
        return;
    }
    let mut boundary = max_bytes;
    while !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    value.truncate(boundary);
}

/// Errors returned before an archive reader is allowed to extract an entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArchiveSafetyError {
    EmptyPath,
    AbsolutePath,
    PathTraversal,
    InvalidPathSeparator,
    ControlCharacter,
    PathTooLong,
    InvalidLimits,
    TooManyEntries,
    EntrySizeExceeded,
    TotalSizeExceeded,
    CompressionRatioExceeded,
    CompressedSizeUnavailable,
    DuplicatePath,
    InvalidArchive,
    UnsupportedArchive,
    EncryptedArchive,
    SourceReadFailed,
}

impl fmt::Display for ArchiveSafetyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::EmptyPath => "archive entry path is empty",
            Self::AbsolutePath => "archive entry path is absolute",
            Self::PathTraversal => "archive entry path contains traversal",
            Self::InvalidPathSeparator => "archive entry path contains a backslash",
            Self::ControlCharacter => "archive entry path contains a control character",
            Self::PathTooLong => "archive entry path exceeds the UTF-8 byte limit",
            Self::InvalidLimits => "archive safety limits must be non-zero",
            Self::TooManyEntries => "archive contains too many entries",
            Self::EntrySizeExceeded => "archive entry exceeds the uncompressed size limit",
            Self::TotalSizeExceeded => "archive exceeds the total uncompressed size limit",
            Self::CompressionRatioExceeded => "archive compression ratio exceeds the limit",
            Self::CompressedSizeUnavailable => {
                "archive entry has no trustworthy packed-size metadata"
            }
            Self::DuplicatePath => "archive contains duplicate entry paths",
            Self::InvalidArchive => "archive container metadata is malformed",
            Self::UnsupportedArchive => "archive uses an unsupported container feature",
            Self::EncryptedArchive => "encrypted archive members are not supported",
            Self::SourceReadFailed => "archive byte source could not satisfy a bounded read",
        })
    }
}

impl std::error::Error for ArchiveSafetyError {}

/// Failure returned by a foreign byte source during archive inspection.
///
/// The public inspection API deliberately converts this to
/// [`ArchiveSafetyError::SourceReadFailed`] so archive callers have one
/// fail-closed result type. Keeping this distinct in the callback contract
/// prevents an exception in Kotlin/Swift from being interpreted as EOF.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArchiveSourceError {
    ReadFailed,
}

impl fmt::Display for ArchiveSourceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("archive byte source read failed")
    }
}

impl std::error::Error for ArchiveSourceError {}

impl From<uniffi::UnexpectedUniFFICallbackError> for ArchiveSourceError {
    fn from(_: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::ReadFailed
    }
}

impl From<ArchiveSourceError> for ArchiveSafetyError {
    fn from(_: ArchiveSourceError) -> Self {
        Self::SourceReadFailed
    }
}

/// A bounded random-access source owned by the calling platform.
///
/// The Rust core only invokes [`ArchiveByteSource::read_at`] with a requested
/// length at or below `64 KiB`, checks the returned length exactly, and never
/// opens a path or retains the source beyond a single inspection call.
pub trait ArchiveByteSource {
    fn length(&self) -> u64;
    fn read_at(&self, offset: u64, length: u32) -> Result<Vec<u8>, ArchiveSourceError>;
}

/// Bounds applied before a platform archive implementation starts extraction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ArchiveLimits {
    pub max_entries: u64,
    pub max_uncompressed_bytes: u64,
    pub max_entry_uncompressed_bytes: u64,
    pub max_compression_ratio: u64,
}

impl Default for ArchiveLimits {
    fn default() -> Self {
        Self {
            max_entries: 10_000,
            max_uncompressed_bytes: 1_073_741_824,     // 1 GiB
            max_entry_uncompressed_bytes: 268_435_456, // 256 MiB
            max_compression_ratio: 100,
        }
    }
}

/// A logical archive member returned by the inspector or supplied to the
/// legacy metadata-only validator.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArchiveEntry {
    pub path: String,
    /// Packed size in bytes when `compressed_size_known` is true.
    pub compressed_size: u64,
    pub uncompressed_size: u64,
    /// Whether `compressed_size` came from trustworthy member metadata.
    /// Metadata-only validation rejects false values. The shared comic
    /// inspector may return false for a member that shares one trusted 7z
    /// packed stream with other members; it validates that stream's aggregate
    /// ratio before constructing the result.
    pub compressed_size_known: bool,
}

/// Aggregate information returned after all entries pass the safety checks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ArchiveInspection {
    pub entry_count: u64,
    pub compressed_bytes: u64,
    pub uncompressed_bytes: u64,
}

/// The validated, real-container enumeration returned by
/// [`inspect_comic_archive`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ComicArchiveInspection {
    pub kind: ArchiveKind,
    pub entries: Vec<ArchiveEntry>,
    pub compressed_bytes: u64,
    pub uncompressed_bytes: u64,
}

/// Validate one archive member path without touching the filesystem.
fn validate_archive_entry_path_ref(path: &str) -> Result<(), ArchiveSafetyError> {
    if path.is_empty() {
        return Err(ArchiveSafetyError::EmptyPath);
    }
    if path.len() > MAX_ARCHIVE_PATH_BYTES {
        return Err(ArchiveSafetyError::PathTooLong);
    }
    if path.starts_with('/') || path.starts_with('\\') || has_windows_drive_prefix(path) {
        return Err(ArchiveSafetyError::AbsolutePath);
    }
    if path.contains('\\') {
        return Err(ArchiveSafetyError::InvalidPathSeparator);
    }
    if path.chars().any(char::is_control) {
        return Err(ArchiveSafetyError::ControlCharacter);
    }
    for component in path.split('/') {
        if component == ".." {
            return Err(ArchiveSafetyError::PathTraversal);
        }
        // A lone dot does not escape the extraction root, but rejecting it
        // keeps the output canonical and avoids duplicate aliases.
        if component == "." {
            return Err(ArchiveSafetyError::PathTraversal);
        }
    }
    Ok(())
}

pub fn validate_archive_entry_path(path: String) -> Result<(), ArchiveSafetyError> {
    validate_archive_entry_path_ref(&path)
}

fn has_windows_drive_prefix(path: &str) -> bool {
    let bytes = path.as_bytes();
    bytes.len() >= 2 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic()
}

/// Validate all archive records before extraction and return bounded totals.
fn inspect_archive_entries_ref(
    entries: &[ArchiveEntry],
    limits: ArchiveLimits,
) -> Result<ArchiveInspection, ArchiveSafetyError> {
    if limits.max_entries == 0
        || limits.max_uncompressed_bytes == 0
        || limits.max_entry_uncompressed_bytes == 0
        || limits.max_compression_ratio == 0
    {
        return Err(ArchiveSafetyError::InvalidLimits);
    }
    if entries.len() as u64 > limits.max_entries {
        return Err(ArchiveSafetyError::TooManyEntries);
    }

    let mut compressed_bytes = 0_u128;
    let mut uncompressed_bytes = 0_u128;
    let mut paths = BTreeSet::new();
    for entry in entries {
        validate_archive_entry_path_ref(&entry.path)?;
        if !paths.insert(entry.path.as_str()) {
            return Err(ArchiveSafetyError::DuplicatePath);
        }
        if entry.uncompressed_size > limits.max_entry_uncompressed_bytes {
            return Err(ArchiveSafetyError::EntrySizeExceeded);
        }
        if !entry.compressed_size_known {
            return Err(ArchiveSafetyError::CompressedSizeUnavailable);
        }
        if entry.compressed_size == 0 {
            if entry.uncompressed_size > 0 {
                return Err(ArchiveSafetyError::CompressionRatioExceeded);
            }
        } else if (entry.uncompressed_size as u128)
            > (entry.compressed_size as u128) * (limits.max_compression_ratio as u128)
        {
            return Err(ArchiveSafetyError::CompressionRatioExceeded);
        }
        compressed_bytes = compressed_bytes
            .checked_add(entry.compressed_size as u128)
            .ok_or(ArchiveSafetyError::TotalSizeExceeded)?;
        uncompressed_bytes = uncompressed_bytes
            .checked_add(entry.uncompressed_size as u128)
            .ok_or(ArchiveSafetyError::TotalSizeExceeded)?;
        if uncompressed_bytes > limits.max_uncompressed_bytes as u128 {
            return Err(ArchiveSafetyError::TotalSizeExceeded);
        }
    }
    // `ArchiveInspection` carries u64 totals; never wrap a malicious central
    // directory while converting the checked u128 accumulator back down.
    if compressed_bytes > u64::MAX as u128 {
        return Err(ArchiveSafetyError::TotalSizeExceeded);
    }
    if compressed_bytes == 0 {
        if uncompressed_bytes > 0 {
            return Err(ArchiveSafetyError::CompressionRatioExceeded);
        }
    } else if uncompressed_bytes > compressed_bytes * (limits.max_compression_ratio as u128) {
        return Err(ArchiveSafetyError::CompressionRatioExceeded);
    }
    Ok(ArchiveInspection {
        entry_count: entries.len() as u64,
        compressed_bytes: compressed_bytes as u64,
        uncompressed_bytes: uncompressed_bytes as u64,
    })
}

pub fn inspect_archive_entries(
    entries: Vec<ArchiveEntry>,
    limits: ArchiveLimits,
) -> Result<ArchiveInspection, ArchiveSafetyError> {
    inspect_archive_entries_ref(&entries, limits)
}

/// A convenience fail-closed check for callers which only need success/fail.
fn validate_archive_entries_ref(
    entries: &[ArchiveEntry],
    limits: ArchiveLimits,
) -> Result<(), ArchiveSafetyError> {
    inspect_archive_entries_ref(entries, limits).map(|_| ())
}

pub fn validate_archive_entries(
    entries: Vec<ArchiveEntry>,
    limits: ArchiveLimits,
) -> Result<(), ArchiveSafetyError> {
    validate_archive_entries_ref(&entries, limits)
}

/// Return the conservative default limits used by mobile importers.
pub fn default_archive_limits() -> ArchiveLimits {
    ArchiveLimits::default()
}

const MAX_ARCHIVE_SOURCE_READ_BYTES: usize = 64 * 1024;
const MAX_ZIP_EOCD_SEARCH_BYTES: usize = 65_557;
const MAX_7Z_HEADER_BYTES: usize = 16 * 1024 * 1024;

/// A trusted compressed/uncompressed group. ZIP and RAR4 have one group per
/// member. A solid 7z folder may cover several logical members, so its pack
/// size is intentionally checked at folder granularity instead of fabricated
/// per-member values.
#[derive(Debug, Clone, Copy)]
struct CompressedGroup {
    compressed_bytes: u64,
    uncompressed_bytes: u64,
}

struct BoundedArchiveReader<'a> {
    source: &'a dyn ArchiveByteSource,
    length: u64,
}

impl<'a> BoundedArchiveReader<'a> {
    fn new(source: &'a dyn ArchiveByteSource) -> Self {
        Self {
            source,
            length: source.length(),
        }
    }

    fn read_exact(&self, offset: u64, length: usize) -> Result<Vec<u8>, ArchiveSafetyError> {
        if length > MAX_ARCHIVE_SOURCE_READ_BYTES {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        self.check_range(offset, length as u64)?;
        let bytes = self.source.read_at(offset, length as u32)?;
        if bytes.len() != length {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        Ok(bytes)
    }

    fn read_bounded(
        &self,
        offset: u64,
        length: u64,
        maximum: usize,
    ) -> Result<Vec<u8>, ArchiveSafetyError> {
        let length = usize::try_from(length).map_err(|_| ArchiveSafetyError::InvalidArchive)?;
        if length > maximum {
            return Err(ArchiveSafetyError::UnsupportedArchive);
        }
        self.check_range(offset, length as u64)?;
        let mut result = Vec::with_capacity(length);
        let mut cursor = offset;
        while result.len() < length {
            let request = (length - result.len()).min(MAX_ARCHIVE_SOURCE_READ_BYTES);
            let bytes = self.read_exact(cursor, request)?;
            result.extend_from_slice(&bytes);
            cursor = cursor
                .checked_add(request as u64)
                .ok_or(ArchiveSafetyError::InvalidArchive)?;
        }
        Ok(result)
    }

    fn check_range(&self, offset: u64, length: u64) -> Result<(), ArchiveSafetyError> {
        let end = offset
            .checked_add(length)
            .ok_or(ArchiveSafetyError::InvalidArchive)?;
        if end > self.length {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        Ok(())
    }
}

fn ensure_archive_limits(limits: ArchiveLimits) -> Result<(), ArchiveSafetyError> {
    if limits.max_entries == 0
        || limits.max_uncompressed_bytes == 0
        || limits.max_entry_uncompressed_bytes == 0
        || limits.max_compression_ratio == 0
    {
        return Err(ArchiveSafetyError::InvalidLimits);
    }
    Ok(())
}

fn checked_add_u64(left: u64, right: u64) -> Result<u64, ArchiveSafetyError> {
    left.checked_add(right)
        .ok_or(ArchiveSafetyError::InvalidArchive)
}

fn le_u16(bytes: &[u8], offset: usize) -> Result<u16, ArchiveSafetyError> {
    let end = offset
        .checked_add(2)
        .ok_or(ArchiveSafetyError::InvalidArchive)?;
    let value = bytes
        .get(offset..end)
        .ok_or(ArchiveSafetyError::InvalidArchive)?;
    Ok(u16::from_le_bytes([value[0], value[1]]))
}

fn le_u32(bytes: &[u8], offset: usize) -> Result<u32, ArchiveSafetyError> {
    let end = offset
        .checked_add(4)
        .ok_or(ArchiveSafetyError::InvalidArchive)?;
    let value = bytes
        .get(offset..end)
        .ok_or(ArchiveSafetyError::InvalidArchive)?;
    Ok(u32::from_le_bytes([value[0], value[1], value[2], value[3]]))
}

fn le_u64(bytes: &[u8], offset: usize) -> Result<u64, ArchiveSafetyError> {
    let end = offset
        .checked_add(8)
        .ok_or(ArchiveSafetyError::InvalidArchive)?;
    let value = bytes
        .get(offset..end)
        .ok_or(ArchiveSafetyError::InvalidArchive)?;
    Ok(u64::from_le_bytes([
        value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7],
    ]))
}

fn decode_archive_path(bytes: &[u8]) -> Result<String, ArchiveSafetyError> {
    let path = std::str::from_utf8(bytes).map_err(|_| ArchiveSafetyError::InvalidArchive)?;
    if path.len() > MAX_ARCHIVE_PATH_BYTES {
        return Err(ArchiveSafetyError::PathTooLong);
    }
    Ok(path.to_owned())
}

fn inspect_real_archive_entries(
    entries: &[ArchiveEntry],
    groups: &[CompressedGroup],
    limits: ArchiveLimits,
) -> Result<ArchiveInspection, ArchiveSafetyError> {
    ensure_archive_limits(limits)?;
    if entries.len() as u64 > limits.max_entries {
        return Err(ArchiveSafetyError::TooManyEntries);
    }

    let mut names = BTreeSet::new();
    let mut uncompressed_total = 0_u128;
    for entry in entries {
        validate_archive_entry_path_ref(&entry.path)?;
        if !names.insert(entry.path.as_str()) {
            return Err(ArchiveSafetyError::DuplicatePath);
        }
        if entry.uncompressed_size > limits.max_entry_uncompressed_bytes {
            return Err(ArchiveSafetyError::EntrySizeExceeded);
        }
        if entry.compressed_size_known {
            if entry.compressed_size == 0 && entry.uncompressed_size > 0 {
                return Err(ArchiveSafetyError::CompressionRatioExceeded);
            }
            if entry.compressed_size > 0
                && (entry.uncompressed_size as u128)
                    > (entry.compressed_size as u128) * (limits.max_compression_ratio as u128)
            {
                return Err(ArchiveSafetyError::CompressionRatioExceeded);
            }
        }
        uncompressed_total = uncompressed_total
            .checked_add(entry.uncompressed_size as u128)
            .ok_or(ArchiveSafetyError::TotalSizeExceeded)?;
        if uncompressed_total > limits.max_uncompressed_bytes as u128 {
            return Err(ArchiveSafetyError::TotalSizeExceeded);
        }
    }

    let mut compressed_total = 0_u128;
    let mut grouped_uncompressed_total = 0_u128;
    for group in groups {
        let compressed = group.compressed_bytes as u128;
        let uncompressed = group.uncompressed_bytes as u128;
        if compressed == 0 && uncompressed > 0 {
            return Err(ArchiveSafetyError::CompressionRatioExceeded);
        }
        if compressed > 0 && uncompressed > compressed * limits.max_compression_ratio as u128 {
            return Err(ArchiveSafetyError::CompressionRatioExceeded);
        }
        compressed_total = compressed_total
            .checked_add(compressed)
            .ok_or(ArchiveSafetyError::TotalSizeExceeded)?;
        grouped_uncompressed_total = grouped_uncompressed_total
            .checked_add(uncompressed)
            .ok_or(ArchiveSafetyError::TotalSizeExceeded)?;
    }
    if grouped_uncompressed_total != uncompressed_total || compressed_total > u64::MAX as u128 {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    if compressed_total == 0 && uncompressed_total > 0 {
        return Err(ArchiveSafetyError::CompressionRatioExceeded);
    }
    if compressed_total > 0
        && uncompressed_total > compressed_total * limits.max_compression_ratio as u128
    {
        return Err(ArchiveSafetyError::CompressionRatioExceeded);
    }
    Ok(ArchiveInspection {
        entry_count: entries.len() as u64,
        compressed_bytes: compressed_total as u64,
        uncompressed_bytes: uncompressed_total as u64,
    })
}

/// Enumerate a CBZ, RAR4 CBR, or unencrypted/unencoded-header CB7 through a
/// bounded callback source. The core validates real container metadata before
/// returning any member. It never extracts a member or keeps a file handle.
pub fn inspect_comic_archive(
    source: Box<dyn ArchiveByteSource>,
    limits: ArchiveLimits,
) -> Result<ComicArchiveInspection, ArchiveSafetyError> {
    ensure_archive_limits(limits)?;
    let reader = BoundedArchiveReader::new(source.as_ref());
    let prefix_length = reader.length.min(8) as usize;
    let prefix = reader.read_exact(0, prefix_length)?;
    let (kind, entries, groups) = match detect_archive_kind_ref(&prefix) {
        ArchiveKind::Zip => {
            let (entries, groups) = inspect_zip_archive(&reader, limits)?;
            (ArchiveKind::Zip, entries, groups)
        }
        ArchiveKind::Rar => {
            let (entries, groups) = inspect_rar4_archive(&reader, limits)?;
            (ArchiveKind::Rar, entries, groups)
        }
        ArchiveKind::SevenZip => {
            let (entries, groups) = inspect_7z_archive(&reader, limits)?;
            (ArchiveKind::SevenZip, entries, groups)
        }
        ArchiveKind::Unknown => return Err(ArchiveSafetyError::InvalidArchive),
    };
    let inspected = inspect_real_archive_entries(&entries, &groups, limits)?;
    Ok(ComicArchiveInspection {
        kind,
        entries,
        compressed_bytes: inspected.compressed_bytes,
        uncompressed_bytes: inspected.uncompressed_bytes,
    })
}

fn inspect_zip_archive(
    reader: &BoundedArchiveReader<'_>,
    limits: ArchiveLimits,
) -> Result<(Vec<ArchiveEntry>, Vec<CompressedGroup>), ArchiveSafetyError> {
    if reader.length < 22 {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    let tail_length = reader.length.min(MAX_ZIP_EOCD_SEARCH_BYTES as u64) as usize;
    let tail_offset = reader.length - tail_length as u64;
    let tail = reader.read_bounded(tail_offset, tail_length as u64, MAX_ZIP_EOCD_SEARCH_BYTES)?;
    let mut eocd_offset = None;
    for relative in (0..=tail.len() - 22).rev() {
        if tail.get(relative..relative + 4) != Some(b"PK\x05\x06") {
            continue;
        }
        let comment_length = le_u16(&tail, relative + 20)? as usize;
        if relative
            .checked_add(22)
            .and_then(|value| value.checked_add(comment_length))
            == Some(tail.len())
        {
            eocd_offset = Some(tail_offset + relative as u64);
            break;
        }
    }
    let eocd_offset = eocd_offset.ok_or(ArchiveSafetyError::InvalidArchive)?;
    let eocd = reader.read_exact(eocd_offset, 22)?;
    let disk = le_u16(&eocd, 4)?;
    let central_disk = le_u16(&eocd, 6)?;
    let entries_on_disk = le_u16(&eocd, 8)?;
    let entry_count = le_u16(&eocd, 10)?;
    let central_size = le_u32(&eocd, 12)? as u64;
    let central_offset = le_u32(&eocd, 16)? as u64;
    if disk != 0
        || central_disk != 0
        || entries_on_disk != entry_count
        || entry_count == u16::MAX
        || central_size == u32::MAX as u64
        || central_offset == u32::MAX as u64
    {
        return Err(ArchiveSafetyError::UnsupportedArchive);
    }
    if entry_count as u64 > limits.max_entries {
        return Err(ArchiveSafetyError::TooManyEntries);
    }
    let central_end = checked_add_u64(central_offset, central_size)?;
    if central_end > eocd_offset {
        return Err(ArchiveSafetyError::InvalidArchive);
    }

    let mut entries = Vec::with_capacity(entry_count as usize);
    let mut groups = Vec::with_capacity(entry_count as usize);
    let mut cursor = central_offset;
    for _ in 0..entry_count {
        let fixed = reader.read_exact(cursor, 46)?;
        if fixed.get(0..4) != Some(b"PK\x01\x02") {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        let flags = le_u16(&fixed, 8)?;
        let method = le_u16(&fixed, 10)?;
        let compressed_size = le_u32(&fixed, 20)? as u64;
        let uncompressed_size = le_u32(&fixed, 24)? as u64;
        let name_length = le_u16(&fixed, 28)? as usize;
        let extra_length = le_u16(&fixed, 30)? as u64;
        let comment_length = le_u16(&fixed, 32)? as u64;
        let disk_start = le_u16(&fixed, 34)?;
        let local_offset = le_u32(&fixed, 42)? as u64;
        if flags & 0x0041 != 0 {
            return Err(ArchiveSafetyError::EncryptedArchive);
        }
        if disk_start != 0 {
            return Err(ArchiveSafetyError::UnsupportedArchive);
        }
        let variable_size = checked_add_u64(
            checked_add_u64(name_length as u64, extra_length)?,
            comment_length,
        )?;
        let next = checked_add_u64(checked_add_u64(cursor, 46)?, variable_size)?;
        if next > eocd_offset {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        let name_bytes = reader.read_bounded(
            checked_add_u64(cursor, 46)?,
            name_length as u64,
            MAX_ARCHIVE_PATH_BYTES,
        )?;
        let path = decode_archive_path(&name_bytes)?;

        let local_fixed = reader.read_exact(local_offset, 30)?;
        if local_fixed.get(0..4) != Some(b"PK\x03\x04")
            || le_u16(&local_fixed, 6)? != flags
            || le_u16(&local_fixed, 8)? != method
        {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        let local_name_length = le_u16(&local_fixed, 26)? as u64;
        let local_extra_length = le_u16(&local_fixed, 28)? as u64;
        let local_name_offset = checked_add_u64(local_offset, 30)?;
        let local_name =
            reader.read_bounded(local_name_offset, local_name_length, MAX_ARCHIVE_PATH_BYTES)?;
        if local_name != name_bytes {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        let data_offset = checked_add_u64(
            checked_add_u64(local_name_offset, local_name_length)?,
            local_extra_length,
        )?;
        if checked_add_u64(data_offset, compressed_size)? > central_offset {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        entries.push(ArchiveEntry {
            path,
            compressed_size,
            uncompressed_size,
            compressed_size_known: true,
        });
        groups.push(CompressedGroup {
            compressed_bytes: compressed_size,
            uncompressed_bytes: uncompressed_size,
        });
        cursor = next;
    }
    if cursor != central_end {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    Ok((entries, groups))
}

fn inspect_rar4_archive(
    reader: &BoundedArchiveReader<'_>,
    limits: ArchiveLimits,
) -> Result<(Vec<ArchiveEntry>, Vec<CompressedGroup>), ArchiveSafetyError> {
    if reader.length < 20 || reader.read_exact(0, 7)? != b"Rar!\x1a\x07\x00" {
        return Err(ArchiveSafetyError::UnsupportedArchive);
    }
    let mut cursor = 7_u64;
    let main = read_rar4_header(reader, cursor)?;
    if main.kind != 0x73 || main.flags & 0x0080 != 0 || main.flags & 0x8000 != 0 {
        return Err(if main.flags & 0x0080 != 0 {
            ArchiveSafetyError::EncryptedArchive
        } else {
            ArchiveSafetyError::InvalidArchive
        });
    }
    if main.bytes.len() < 13 {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    cursor = checked_add_u64(cursor, main.bytes.len() as u64)?;

    let mut entries = Vec::new();
    let mut groups = Vec::new();
    loop {
        if cursor >= reader.length {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        let header = read_rar4_header(reader, cursor)?;
        match header.kind {
            0x74 => {
                if entries.len() as u64 >= limits.max_entries {
                    return Err(ArchiveSafetyError::TooManyEntries);
                }
                let (entry, group, next) = parse_rar4_file_header(&header, cursor, reader.length)?;
                entries.push(entry);
                groups.push(group);
                cursor = next;
            }
            0x7b => {
                if checked_add_u64(cursor, header.bytes.len() as u64)? != reader.length {
                    return Err(ArchiveSafetyError::InvalidArchive);
                }
                return Ok((entries, groups));
            }
            _ => return Err(ArchiveSafetyError::UnsupportedArchive),
        }
    }
}

struct Rar4Header {
    kind: u8,
    flags: u16,
    bytes: Vec<u8>,
}

fn read_rar4_header(
    reader: &BoundedArchiveReader<'_>,
    offset: u64,
) -> Result<Rar4Header, ArchiveSafetyError> {
    let base = reader.read_exact(offset, 7)?;
    let header_size = le_u16(&base, 5)? as usize;
    if header_size < 7 {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    let bytes = reader.read_bounded(offset, header_size as u64, MAX_ARCHIVE_SOURCE_READ_BYTES)?;
    if le_u16(&bytes, 0)? != rar4_header_crc(&bytes[2..]) {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    Ok(Rar4Header {
        kind: bytes[2],
        flags: le_u16(&bytes, 3)?,
        bytes,
    })
}

fn parse_rar4_file_header(
    header: &Rar4Header,
    offset: u64,
    archive_length: u64,
) -> Result<(ArchiveEntry, CompressedGroup, u64), ArchiveSafetyError> {
    const RAR_FILE_FIXED_BYTES: usize = 7 + 4 + 21;
    if header.bytes.len() < RAR_FILE_FIXED_BYTES {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    if header.flags & 0x0004 != 0 {
        return Err(ArchiveSafetyError::EncryptedArchive);
    }
    if header.flags & 0x0003 != 0 || header.flags & 0x0200 != 0 {
        return Err(ArchiveSafetyError::UnsupportedArchive);
    }
    let packed_low = le_u32(&header.bytes, 7)? as u64;
    let unpacked_low = le_u32(&header.bytes, 11)? as u64;
    let name_length = le_u16(&header.bytes, 22)? as usize;
    let mut name_offset = 28_usize;
    let (compressed_size, uncompressed_size) = if header.flags & 0x0100 != 0 {
        if header.bytes.len() < name_offset + 8 {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        let packed_high = le_u32(&header.bytes, name_offset)? as u64;
        let unpacked_high = le_u32(&header.bytes, name_offset + 4)? as u64;
        name_offset += 8;
        (
            (packed_high << 32) | packed_low,
            (unpacked_high << 32) | unpacked_low,
        )
    } else {
        (packed_low, unpacked_low)
    };
    let name_end = name_offset
        .checked_add(name_length)
        .ok_or(ArchiveSafetyError::InvalidArchive)?;
    if name_end > header.bytes.len() {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    let path = decode_archive_path(&header.bytes[name_offset..name_end])?;
    let data_offset = checked_add_u64(offset, header.bytes.len() as u64)?;
    let next = checked_add_u64(data_offset, compressed_size)?;
    if next > archive_length {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    Ok((
        ArchiveEntry {
            path,
            compressed_size,
            uncompressed_size,
            compressed_size_known: true,
        },
        CompressedGroup {
            compressed_bytes: compressed_size,
            uncompressed_bytes: uncompressed_size,
        },
        next,
    ))
}

/// RAR4 stores the low 16 bits of its non-finalized IEEE CRC-32 state in
/// every header. This differs from ZIP's finalized CRC-32 field.
fn rar4_header_crc(bytes: &[u8]) -> u16 {
    (!crc32(bytes)) as u16
}

#[derive(Debug)]
struct SevenZipFolder {
    packed_stream_count: usize,
    output_count: usize,
    final_output_index: usize,
    unpack_sizes: Vec<u64>,
    has_crc: bool,
    num_substreams: usize,
}

impl SevenZipFolder {
    fn unpacked_size(&self) -> Result<u64, ArchiveSafetyError> {
        self.unpack_sizes
            .get(self.final_output_index)
            .copied()
            .ok_or(ArchiveSafetyError::InvalidArchive)
    }
}

#[derive(Debug)]
struct SevenZipStreams {
    pack_pos: u64,
    pack_sizes: Vec<u64>,
    folders: Vec<SevenZipFolder>,
    substream_sizes: Vec<u64>,
}

#[derive(Debug)]
struct SevenZipFiles {
    paths: Vec<String>,
    empty_streams: Vec<bool>,
}

struct SevenZipCursor<'a> {
    bytes: &'a [u8],
    position: usize,
}

impl<'a> SevenZipCursor<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, position: 0 }
    }

    fn remaining(&self) -> usize {
        self.bytes.len().saturating_sub(self.position)
    }

    fn read_u8(&mut self) -> Result<u8, ArchiveSafetyError> {
        let value = *self
            .bytes
            .get(self.position)
            .ok_or(ArchiveSafetyError::InvalidArchive)?;
        self.position += 1;
        Ok(value)
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8], ArchiveSafetyError> {
        let end = self
            .position
            .checked_add(length)
            .ok_or(ArchiveSafetyError::InvalidArchive)?;
        let value = self
            .bytes
            .get(self.position..end)
            .ok_or(ArchiveSafetyError::InvalidArchive)?;
        self.position = end;
        Ok(value)
    }

    fn skip(&mut self, length: usize) -> Result<(), ArchiveSafetyError> {
        self.take(length).map(|_| ())
    }

    fn read_uint64(&mut self) -> Result<u64, ArchiveSafetyError> {
        let first = self.read_u8()?;
        let mut mask = 0x80_u8;
        let mut value = 0_u64;
        for index in 0..8 {
            if first & mask == 0 {
                return Ok(value | (((first & (mask - 1)) as u64) << (8 * index)));
            }
            value |= (self.read_u8()? as u64) << (8 * index);
            mask >>= 1;
        }
        Ok(value)
    }

    fn read_bits(&mut self, count: usize) -> Result<Vec<bool>, ArchiveSafetyError> {
        let byte_count = count
            .checked_add(7)
            .ok_or(ArchiveSafetyError::InvalidArchive)?
            / 8;
        let bytes = self.take(byte_count)?;
        let mut result = Vec::with_capacity(count);
        for index in 0..count {
            result.push(bytes[index / 8] & (0x80 >> (index % 8)) != 0);
        }
        Ok(result)
    }

    fn read_all_or_bits(&mut self, count: usize) -> Result<Vec<bool>, ArchiveSafetyError> {
        if self.read_u8()? != 0 {
            Ok(vec![true; count])
        } else {
            self.read_bits(count)
        }
    }
}

fn inspect_7z_archive(
    reader: &BoundedArchiveReader<'_>,
    limits: ArchiveLimits,
) -> Result<(Vec<ArchiveEntry>, Vec<CompressedGroup>), ArchiveSafetyError> {
    if reader.length < 32 {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    let signature = reader.read_exact(0, 32)?;
    if signature.get(0..6) != Some(b"7z\xbc\xaf\x27\x1c") {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    if signature[6] != 0 {
        return Err(ArchiveSafetyError::UnsupportedArchive);
    }
    if le_u32(&signature, 8)? != crc32(&signature[12..32]) {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    let next_header_offset = checked_add_u64(32, le_u64(&signature, 12)?)?;
    let next_header_size = le_u64(&signature, 20)?;
    let next_header_end = checked_add_u64(next_header_offset, next_header_size)?;
    if next_header_end != reader.length {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    let header = reader.read_bounded(next_header_offset, next_header_size, MAX_7Z_HEADER_BYTES)?;
    if le_u32(&signature, 28)? != crc32(&header) {
        return Err(ArchiveSafetyError::InvalidArchive);
    }

    let mut cursor = SevenZipCursor::new(&header);
    match cursor.read_u8()? {
        0x01 => {}
        0x17 => return Err(ArchiveSafetyError::UnsupportedArchive),
        _ => return Err(ArchiveSafetyError::InvalidArchive),
    }
    let (streams, files) = parse_7z_header(&mut cursor, limits)?;
    if cursor.remaining() != 0 {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    let packed_data_start = checked_add_u64(32, streams.pack_pos)?;
    let packed_data_size = streams
        .pack_sizes
        .iter()
        .try_fold(0_u64, |sum, size| checked_add_u64(sum, *size))?;
    if packed_data_start > next_header_offset
        || checked_add_u64(packed_data_start, packed_data_size)? > next_header_offset
    {
        return Err(ArchiveSafetyError::InvalidArchive);
    }

    let nonempty_count = files.empty_streams.iter().filter(|empty| !**empty).count();
    if streams.substream_sizes.len() != nonempty_count {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    let mut groups = Vec::with_capacity(streams.folders.len());
    let mut member_packed_sizes = Vec::with_capacity(nonempty_count);
    let mut pack_cursor = 0_usize;
    let mut substream_cursor = 0_usize;
    for folder in &streams.folders {
        let pack_end = pack_cursor
            .checked_add(folder.packed_stream_count)
            .ok_or(ArchiveSafetyError::InvalidArchive)?;
        let compressed = streams
            .pack_sizes
            .get(pack_cursor..pack_end)
            .ok_or(ArchiveSafetyError::InvalidArchive)?
            .iter()
            .try_fold(0_u64, |sum, value| checked_add_u64(sum, *value))?;
        let substream_end = substream_cursor
            .checked_add(folder.num_substreams)
            .ok_or(ArchiveSafetyError::InvalidArchive)?;
        let unpacked = streams
            .substream_sizes
            .get(substream_cursor..substream_end)
            .ok_or(ArchiveSafetyError::InvalidArchive)?
            .iter()
            .try_fold(0_u64, |sum, value| checked_add_u64(sum, *value))?;
        if unpacked != folder.unpacked_size()? {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        groups.push(CompressedGroup {
            compressed_bytes: compressed,
            uncompressed_bytes: unpacked,
        });
        for _ in 0..folder.num_substreams {
            member_packed_sizes.push((folder.num_substreams == 1).then_some(compressed));
        }
        pack_cursor = pack_end;
        substream_cursor = substream_end;
    }
    if pack_cursor != streams.pack_sizes.len() || substream_cursor != nonempty_count {
        return Err(ArchiveSafetyError::InvalidArchive);
    }

    let mut entries = Vec::with_capacity(files.paths.len());
    let mut member_cursor = 0_usize;
    for (path, empty) in files.paths.into_iter().zip(files.empty_streams) {
        let (compressed_size, uncompressed_size, compressed_size_known) = if empty {
            (0, 0, true)
        } else {
            let uncompressed = *streams
                .substream_sizes
                .get(member_cursor)
                .ok_or(ArchiveSafetyError::InvalidArchive)?;
            let packed = *member_packed_sizes
                .get(member_cursor)
                .ok_or(ArchiveSafetyError::InvalidArchive)?;
            member_cursor += 1;
            match packed {
                Some(size) => (size, uncompressed, true),
                None => (0, uncompressed, false),
            }
        };
        entries.push(ArchiveEntry {
            path,
            compressed_size,
            uncompressed_size,
            compressed_size_known,
        });
    }
    if member_cursor != nonempty_count {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    Ok((entries, groups))
}

fn parse_7z_header(
    cursor: &mut SevenZipCursor<'_>,
    limits: ArchiveLimits,
) -> Result<(SevenZipStreams, SevenZipFiles), ArchiveSafetyError> {
    let mut next = cursor.read_u8()?;
    if next == 0x02 {
        skip_7z_archive_properties(cursor)?;
        next = cursor.read_u8()?;
    }
    if next == 0x03 {
        return Err(ArchiveSafetyError::UnsupportedArchive);
    }
    if next != 0x04 {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    let streams = parse_7z_streams_info(cursor, limits)?;
    next = cursor.read_u8()?;
    if next != 0x05 {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    let files = parse_7z_files_info(cursor, limits)?;
    if cursor.read_u8()? != 0x00 {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    Ok((streams, files))
}

fn skip_7z_archive_properties(cursor: &mut SevenZipCursor<'_>) -> Result<(), ArchiveSafetyError> {
    loop {
        if cursor.read_uint64()? == 0 {
            return Ok(());
        }
        let size = usize::try_from(cursor.read_uint64()?)
            .map_err(|_| ArchiveSafetyError::InvalidArchive)?;
        cursor.skip(size)?;
    }
}

fn checked_7z_count(value: u64, maximum: u64) -> Result<usize, ArchiveSafetyError> {
    if value > maximum {
        return Err(ArchiveSafetyError::TooManyEntries);
    }
    usize::try_from(value).map_err(|_| ArchiveSafetyError::InvalidArchive)
}

fn parse_7z_streams_info(
    cursor: &mut SevenZipCursor<'_>,
    limits: ArchiveLimits,
) -> Result<SevenZipStreams, ArchiveSafetyError> {
    let max_streams = limits.max_entries.saturating_mul(16).max(16);
    let mut next = cursor.read_u8()?;
    let (pack_pos, pack_sizes) = if next == 0x06 {
        let pack_pos = cursor.read_uint64()?;
        let pack_count = checked_7z_count(cursor.read_uint64()?, max_streams)?;
        if pack_count == 0 || cursor.read_u8()? != 0x09 {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        let mut pack_sizes = Vec::with_capacity(pack_count);
        for _ in 0..pack_count {
            pack_sizes.push(cursor.read_uint64()?);
        }
        next = cursor.read_u8()?;
        if next == 0x0a {
            let crc_present = cursor.read_all_or_bits(pack_count)?;
            for present in crc_present {
                if present {
                    cursor.skip(4)?;
                }
            }
            next = cursor.read_u8()?;
        }
        if next != 0x00 {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        next = cursor.read_u8()?;
        (pack_pos, pack_sizes)
    } else {
        (0, Vec::new())
    };
    if next != 0x07 {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    next = cursor.read_u8()?;
    let mut folders = if next == 0x0b {
        let folder_count = checked_7z_count(cursor.read_uint64()?, limits.max_entries)?;
        if folder_count == 0 || cursor.read_u8()? != 0 {
            return Err(ArchiveSafetyError::UnsupportedArchive);
        }
        let mut folders = Vec::with_capacity(folder_count);
        for _ in 0..folder_count {
            folders.push(parse_7z_folder(cursor, max_streams)?);
        }
        if cursor.read_u8()? != 0x0c {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        for folder in &mut folders {
            folder.unpack_sizes.reserve(folder.output_count);
            for _ in 0..folder.output_count {
                folder.unpack_sizes.push(cursor.read_uint64()?);
            }
        }
        next = cursor.read_u8()?;
        if next == 0x0a {
            let crc_present = cursor.read_all_or_bits(folder_count)?;
            for (folder, present) in folders.iter_mut().zip(crc_present) {
                folder.has_crc = present;
                if present {
                    cursor.skip(4)?;
                }
            }
            next = cursor.read_u8()?;
        }
        if next != 0x00 {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        next = cursor.read_u8()?;
        folders
    } else {
        Vec::new()
    };
    if next == 0x08 {
        next = cursor.read_u8()?;
    }
    let substream_sizes = if folders.is_empty() {
        if !pack_sizes.is_empty() || next != 0x00 {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        Vec::new()
    } else {
        parse_7z_substreams_info(cursor, &mut folders, limits, next)?
    };
    Ok(SevenZipStreams {
        pack_pos,
        pack_sizes,
        folders,
        substream_sizes,
    })
}

fn parse_7z_folder(
    cursor: &mut SevenZipCursor<'_>,
    max_streams: u64,
) -> Result<SevenZipFolder, ArchiveSafetyError> {
    let coder_count = checked_7z_count(cursor.read_uint64()?, max_streams)?;
    if coder_count == 0 {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    let mut total_inputs = 0_u64;
    let mut total_outputs = 0_u64;
    for _ in 0..coder_count {
        let flags = cursor.read_u8()?;
        let id_size = (flags & 0x0f) as usize;
        if id_size == 0 {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        let method = cursor.take(id_size)?;
        if method == [0x06, 0xf1, 0x07, 0x01] {
            return Err(ArchiveSafetyError::EncryptedArchive);
        }
        if flags & 0x80 != 0 {
            return Err(ArchiveSafetyError::UnsupportedArchive);
        }
        let (inputs, outputs) = if flags & 0x10 == 0 {
            (1, 1)
        } else {
            (cursor.read_uint64()?, cursor.read_uint64()?)
        };
        if inputs == 0 || outputs == 0 {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        total_inputs = checked_add_u64(total_inputs, inputs)?;
        total_outputs = checked_add_u64(total_outputs, outputs)?;
        if total_inputs > max_streams || total_outputs > max_streams {
            return Err(ArchiveSafetyError::TooManyEntries);
        }
        if flags & 0x20 != 0 {
            let property_size = usize::try_from(cursor.read_uint64()?)
                .map_err(|_| ArchiveSafetyError::InvalidArchive)?;
            cursor.skip(property_size)?;
        }
    }
    let input_count = checked_7z_count(total_inputs, max_streams)?;
    let output_count = checked_7z_count(total_outputs, max_streams)?;
    let bind_count = output_count
        .checked_sub(1)
        .ok_or(ArchiveSafetyError::InvalidArchive)?;
    let mut bound_inputs = BTreeSet::new();
    let mut bound_outputs = BTreeSet::new();
    for _ in 0..bind_count {
        let input = checked_7z_count(cursor.read_uint64()?, total_inputs)?;
        let output = checked_7z_count(cursor.read_uint64()?, total_outputs)?;
        if !bound_inputs.insert(input) || !bound_outputs.insert(output) {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
    }
    let packed_stream_count = input_count
        .checked_sub(bind_count)
        .ok_or(ArchiveSafetyError::InvalidArchive)?;
    if packed_stream_count == 0 {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    if packed_stream_count == 1 {
        if (0..input_count).all(|index| bound_inputs.contains(&index)) {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
    } else {
        let mut packed_inputs = BTreeSet::new();
        for _ in 0..packed_stream_count {
            let input = checked_7z_count(cursor.read_uint64()?, total_inputs)?;
            if bound_inputs.contains(&input) || !packed_inputs.insert(input) {
                return Err(ArchiveSafetyError::InvalidArchive);
            }
        }
    }
    let final_output_index = (0..output_count)
        .rev()
        .find(|index| !bound_outputs.contains(index))
        .ok_or(ArchiveSafetyError::InvalidArchive)?;
    Ok(SevenZipFolder {
        packed_stream_count,
        output_count,
        final_output_index,
        unpack_sizes: Vec::new(),
        has_crc: false,
        num_substreams: 1,
    })
}

fn parse_7z_substreams_info(
    cursor: &mut SevenZipCursor<'_>,
    folders: &mut [SevenZipFolder],
    limits: ArchiveLimits,
    mut next: u8,
) -> Result<Vec<u64>, ArchiveSafetyError> {
    if next == 0x0d {
        let mut total = 0_u64;
        for folder in folders.iter_mut() {
            folder.num_substreams = checked_7z_count(cursor.read_uint64()?, limits.max_entries)?;
            total = checked_add_u64(total, folder.num_substreams as u64)?;
            if total > limits.max_entries {
                return Err(ArchiveSafetyError::TooManyEntries);
            }
        }
        next = cursor.read_u8()?;
    }
    let mut sizes = Vec::new();
    for folder in folders.iter() {
        if folder.num_substreams == 0 {
            continue;
        }
        let folder_unpacked = folder.unpacked_size()?;
        if folder.num_substreams == 1 {
            sizes.push(folder_unpacked);
            continue;
        }
        if next != 0x09 {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        let mut sum = 0_u64;
        for _ in 0..folder.num_substreams - 1 {
            let size = cursor.read_uint64()?;
            sum = checked_add_u64(sum, size)?;
            if sum > folder_unpacked {
                return Err(ArchiveSafetyError::InvalidArchive);
            }
            sizes.push(size);
        }
        sizes.push(folder_unpacked - sum);
    }
    if next == 0x09 {
        next = cursor.read_u8()?;
    }
    let digest_count = folders.iter().try_fold(0_usize, |total, folder| {
        let count = if folder.num_substreams != 1 || !folder.has_crc {
            folder.num_substreams
        } else {
            0
        };
        total
            .checked_add(count)
            .ok_or(ArchiveSafetyError::InvalidArchive)
    })?;
    if next == 0x0a {
        let present = cursor.read_all_or_bits(digest_count)?;
        for has_digest in present {
            if has_digest {
                cursor.skip(4)?;
            }
        }
        next = cursor.read_u8()?;
    }
    if next != 0x00 {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    Ok(sizes)
}

fn parse_7z_files_info(
    cursor: &mut SevenZipCursor<'_>,
    limits: ArchiveLimits,
) -> Result<SevenZipFiles, ArchiveSafetyError> {
    let declared_count = cursor.read_uint64()?;
    let count = checked_7z_count(declared_count, limits.max_entries)?;
    let mut empty_streams = vec![false; count];
    let mut names = None;
    loop {
        let property = cursor.read_u8()?;
        if property == 0x00 {
            break;
        }
        let property_size = usize::try_from(cursor.read_uint64()?)
            .map_err(|_| ArchiveSafetyError::InvalidArchive)?;
        let property_end = cursor
            .position
            .checked_add(property_size)
            .ok_or(ArchiveSafetyError::InvalidArchive)?;
        if property_end > cursor.bytes.len() {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
        match property {
            0x0e => {
                empty_streams = cursor.read_bits(count)?;
            }
            0x0f | 0x10 => {
                let empty_count = empty_streams.iter().filter(|empty| **empty).count();
                cursor.read_bits(empty_count)?;
            }
            0x11 => {
                if cursor.read_u8()? != 0 {
                    return Err(ArchiveSafetyError::UnsupportedArchive);
                }
                let raw = cursor.take(property_end - cursor.position)?;
                names = Some(parse_7z_utf16_names(raw, count)?);
            }
            0x18 => return Err(ArchiveSafetyError::UnsupportedArchive),
            _ => cursor.skip(property_end - cursor.position)?,
        }
        if cursor.position != property_end {
            return Err(ArchiveSafetyError::InvalidArchive);
        }
    }
    Ok(SevenZipFiles {
        paths: names.ok_or(ArchiveSafetyError::InvalidArchive)?,
        empty_streams,
    })
}

fn parse_7z_utf16_names(
    raw: &[u8],
    expected_count: usize,
) -> Result<Vec<String>, ArchiveSafetyError> {
    // Keep the format core compatible with the repository's pinned Rust 1.85
    // toolchain. `usize::is_multiple_of` is not stable on that compiler.
    if raw.len() % 2 != 0 {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    let mut names = Vec::with_capacity(expected_count);
    let mut current = Vec::new();
    for pair in raw.chunks_exact(2) {
        let unit = u16::from_le_bytes([pair[0], pair[1]]);
        if unit == 0 {
            let path =
                String::from_utf16(&current).map_err(|_| ArchiveSafetyError::InvalidArchive)?;
            if path.len() > MAX_ARCHIVE_PATH_BYTES {
                return Err(ArchiveSafetyError::PathTooLong);
            }
            names.push(path);
            current.clear();
        } else {
            current.push(unit);
        }
    }
    if !current.is_empty() || names.len() != expected_count {
        return Err(ArchiveSafetyError::InvalidArchive);
    }
    Ok(names)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{self, Cursor, Read};

    struct MemorySource(Vec<u8>);

    impl ArchiveByteSource for MemorySource {
        fn length(&self) -> u64 {
            self.0.len() as u64
        }

        fn read_at(&self, offset: u64, length: u32) -> Result<Vec<u8>, ArchiveSourceError> {
            let start = usize::try_from(offset).map_err(|_| ArchiveSourceError::ReadFailed)?;
            let end = start
                .checked_add(length as usize)
                .ok_or(ArchiveSourceError::ReadFailed)?;
            self.0
                .get(start..end)
                .map(ToOwned::to_owned)
                .ok_or(ArchiveSourceError::ReadFailed)
        }
    }

    fn inspect_bytes(
        bytes: Vec<u8>,
        limits: ArchiveLimits,
    ) -> Result<ComicArchiveInspection, ArchiveSafetyError> {
        super::inspect_comic_archive(Box::new(MemorySource(bytes)), limits)
    }

    fn test_limits() -> ArchiveLimits {
        ArchiveLimits {
            max_entries: 16,
            max_uncompressed_bytes: 1024,
            max_entry_uncompressed_bytes: 512,
            max_compression_ratio: 100,
        }
    }

    fn make_stored_zip(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut output = Vec::new();
        let mut central = Vec::new();
        for (name, bytes) in entries {
            let offset = output.len() as u32;
            let name = name.as_bytes();
            let size = bytes.len() as u32;
            output.extend_from_slice(b"PK\x03\x04");
            output.extend_from_slice(&20_u16.to_le_bytes());
            output.extend_from_slice(&0_u16.to_le_bytes());
            output.extend_from_slice(&0_u16.to_le_bytes());
            output.extend_from_slice(&0_u16.to_le_bytes());
            output.extend_from_slice(&0_u16.to_le_bytes());
            output.extend_from_slice(&crc32(bytes).to_le_bytes());
            output.extend_from_slice(&size.to_le_bytes());
            output.extend_from_slice(&size.to_le_bytes());
            output.extend_from_slice(&(name.len() as u16).to_le_bytes());
            output.extend_from_slice(&0_u16.to_le_bytes());
            output.extend_from_slice(name);
            output.extend_from_slice(bytes);

            central.extend_from_slice(b"PK\x01\x02");
            central.extend_from_slice(&20_u16.to_le_bytes());
            central.extend_from_slice(&20_u16.to_le_bytes());
            central.extend_from_slice(&0_u16.to_le_bytes());
            central.extend_from_slice(&0_u16.to_le_bytes());
            central.extend_from_slice(&0_u16.to_le_bytes());
            central.extend_from_slice(&0_u16.to_le_bytes());
            central.extend_from_slice(&crc32(bytes).to_le_bytes());
            central.extend_from_slice(&size.to_le_bytes());
            central.extend_from_slice(&size.to_le_bytes());
            central.extend_from_slice(&(name.len() as u16).to_le_bytes());
            central.extend_from_slice(&0_u16.to_le_bytes());
            central.extend_from_slice(&0_u16.to_le_bytes());
            central.extend_from_slice(&0_u16.to_le_bytes());
            central.extend_from_slice(&0_u16.to_le_bytes());
            central.extend_from_slice(&0_u32.to_le_bytes());
            central.extend_from_slice(&offset.to_le_bytes());
            central.extend_from_slice(name);
        }
        let central_offset = output.len() as u32;
        let central_size = central.len() as u32;
        output.extend_from_slice(&central);
        output.extend_from_slice(b"PK\x05\x06");
        output.extend_from_slice(&[0, 0, 0, 0]);
        output.extend_from_slice(&(entries.len() as u16).to_le_bytes());
        output.extend_from_slice(&(entries.len() as u16).to_le_bytes());
        output.extend_from_slice(&central_size.to_le_bytes());
        output.extend_from_slice(&central_offset.to_le_bytes());
        output.extend_from_slice(&0_u16.to_le_bytes());
        output
    }

    fn rar4_header(kind: u8, body_without_crc: &[u8]) -> Vec<u8> {
        let mut body = Vec::with_capacity(1 + body_without_crc.len());
        body.push(kind);
        body.extend_from_slice(body_without_crc);
        let crc = (!crc32(&body)) as u16;
        let mut header = Vec::with_capacity(2 + body.len());
        header.extend_from_slice(&crc.to_le_bytes());
        header.extend_from_slice(&body);
        header
    }

    fn make_empty_rar4() -> Vec<u8> {
        let mut output = b"Rar!\x1a\x07\x00".to_vec();
        output.extend_from_slice(&rar4_header(0x73, &[0, 0, 13, 0, 0, 0, 0, 0, 0, 0]));
        output.extend_from_slice(&rar4_header(0x7b, &[0, 0, 7, 0]));
        output
    }

    fn make_minimal_7z(path: &str, packed: u64, unpacked: u64) -> Vec<u8> {
        let mut header = Vec::new();
        header.push(0x01);
        header.push(0x04);
        header.push(0x06);
        header.extend_from_slice(&encode_7z_uint64(0));
        header.extend_from_slice(&encode_7z_uint64(1));
        header.push(0x09);
        header.extend_from_slice(&encode_7z_uint64(packed));
        header.push(0x00);
        header.push(0x07);
        header.push(0x0b);
        header.extend_from_slice(&encode_7z_uint64(1));
        header.push(0x00);
        header.push(0x01);
        header.push(0x01);
        header.push(0x00);
        header.push(0x0c);
        header.extend_from_slice(&encode_7z_uint64(unpacked));
        header.push(0x00);
        // End UnpackInfo, then end the enclosing StreamsInfo.
        header.push(0x00);
        header.push(0x05);
        header.extend_from_slice(&encode_7z_uint64(1));
        let name_bytes: Vec<u8> = path
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .chain([0, 0])
            .collect();
        let property_size = 1 + name_bytes.len();
        header.push(0x11);
        header.extend_from_slice(&encode_7z_uint64(property_size as u64));
        header.push(0x00);
        header.extend_from_slice(&name_bytes);
        header.push(0x00);
        header.push(0x00);

        let next_header_offset = packed;
        let next_header_size = header.len() as u64;
        let mut signature = Vec::new();
        signature.extend_from_slice(b"7z\xbc\xaf\x27\x1c");
        signature.extend_from_slice(&[0, 4]);
        let mut start_header = Vec::with_capacity(20);
        start_header.extend_from_slice(&next_header_offset.to_le_bytes());
        start_header.extend_from_slice(&next_header_size.to_le_bytes());
        start_header.extend_from_slice(&crc32(&header).to_le_bytes());
        signature.extend_from_slice(&crc32(&start_header).to_le_bytes());
        signature.extend_from_slice(&next_header_offset.to_le_bytes());
        signature.extend_from_slice(&next_header_size.to_le_bytes());
        signature.extend_from_slice(&crc32(&header).to_le_bytes());
        signature.extend_from_slice(&vec![0_u8; packed as usize]);
        signature.extend_from_slice(&header);
        signature
    }

    fn encode_7z_uint64(value: u64) -> Vec<u8> {
        for extra in 0..8 {
            let payload_bits = 7 - extra;
            if value < (1_u64 << (8 * extra + payload_bits)) {
                let prefix = if extra == 0 {
                    0
                } else {
                    (0xff_u16 << (8 - extra)) as u8
                };
                let first = prefix | ((value >> (8 * extra)) as u8 & ((1 << payload_bits) - 1));
                let mut result = vec![first];
                for byte in 0..extra {
                    result.push((value >> (8 * byte)) as u8);
                }
                return result;
            }
        }
        let mut result = vec![0xff];
        for byte in 0..8 {
            result.push((value >> (8 * byte)) as u8);
        }
        result
    }

    // Keep the Rust unit tests borrowing input while the public UniFFI
    // boundary takes owned strings/byte vectors. This avoids extra copies in
    // native callers without weakening the generated binding signatures.
    fn archive_kind_from_extension(value: &str) -> Option<ArchiveKind> {
        super::archive_kind_from_extension_ref(value)
    }
    fn convert_to_internal_epub(
        format: SupportedFormat,
        input: &[u8],
    ) -> Result<Vec<u8>, ConversionError> {
        super::convert_to_internal_epub_ref(format, input)
    }
    fn sha256_hex(input: &[u8]) -> String {
        super::sha256_hex_ref(input)
    }
    fn converter_cache_key(source: &str, version: &str) -> String {
        super::converter_cache_key_ref(source, version)
    }
    fn detect_archive_kind(input: &[u8]) -> ArchiveKind {
        super::detect_archive_kind_ref(input)
    }
    fn detect_format(filename: &str, header: &[u8]) -> Option<SupportedFormat> {
        super::detect_format_ref(filename, header)
    }
    fn validate_filename(value: &str) -> Result<(), FilenameSafetyError> {
        super::validate_filename_ref(value)
    }
    fn sanitize_filename(value: &str) -> String {
        super::sanitize_filename_ref(value)
    }
    fn validate_archive_entry_path(value: &str) -> Result<(), ArchiveSafetyError> {
        super::validate_archive_entry_path_ref(value)
    }
    fn inspect_archive_entries(
        entries: &[ArchiveEntry],
        limits: ArchiveLimits,
    ) -> Result<ArchiveInspection, ArchiveSafetyError> {
        super::inspect_archive_entries_ref(entries, limits)
    }
    fn validate_archive_entries(
        entries: &[ArchiveEntry],
        limits: ArchiveLimits,
    ) -> Result<(), ArchiveSafetyError> {
        super::validate_archive_entries_ref(entries, limits)
    }
    fn convert_fb2_to_html(value: &str) -> Result<String, ConversionError> {
        super::convert_fb2_to_html_ref(value)
    }
    fn convert_to_internal_html(
        format: SupportedFormat,
        input: &[u8],
    ) -> Result<String, ConversionError> {
        super::convert_to_internal_html_ref(format, input)
    }

    #[test]
    fn recognizes_every_bookorbit_format() {
        let formats = [
            "epub", "kepub", "mobi", "azw", "azw3", "fb2", "pdf", "cbz", "cbr", "cb7", "m4b",
            "m4a", "mp3", "opus", "ogg", "flac",
        ];
        assert!(formats
            .iter()
            .all(|extension| SupportedFormat::from_extension(extension).is_some()));
        assert_eq!(
            SupportedFormat::from_extension(" .EPUB "),
            Some(SupportedFormat::Epub)
        );
        assert_eq!(SupportedFormat::from_extension("..epub"), None);
    }

    #[test]
    fn uses_converter_for_kindle_and_fb2_text() {
        assert_eq!(
            SupportedFormat::Mobi.strategy(),
            ReaderStrategy::ConvertToEpub
        );
        assert_eq!(
            SupportedFormat::Azw3.strategy(),
            ReaderStrategy::ConvertToEpub
        );
        assert_eq!(
            SupportedFormat::Fb2.strategy(),
            ReaderStrategy::ConvertToEpub
        );
        assert_eq!(
            reader_strategy(SupportedFormat::Pdf),
            ReaderStrategy::ReadiumPdf
        );
        assert_eq!(archive_kind_from_extension("cbz"), Some(ArchiveKind::Zip));
        assert_eq!(
            archive_kind_from_format(SupportedFormat::Cbr),
            Some(ArchiveKind::Rar)
        );
    }

    #[test]
    fn mobi_markup_maps_only_validated_internal_images() {
        let images = vec![MobiImage {
            name: "mobi-0000.jpg".to_owned(),
            media_type: "image/jpeg",
            bytes: vec![0xff, 0xd8, 0xff],
        }];
        let html = mobi_markup_to_html(
            "<p>Hello</p><img src=\"external-url\"><script>bad()</script>",
            &images,
        );
        assert!(html.contains("<img src=\"Images/mobi-0000.jpg\""));
        assert!(!html.contains("external-url"));
        assert!(!html.contains("script"));
    }

    #[test]
    fn writes_a_valid_deterministic_internal_epub_container() {
        let first = convert_to_internal_epub(SupportedFormat::Fb2, br#"<FictionBook><body><section><title>Chapter</title><p>Hello</p></section></body></FictionBook>"#).unwrap();
        let second = convert_to_internal_epub(SupportedFormat::Fb2, br#"<FictionBook><body><section><title>Chapter</title><p>Hello</p></section></body></FictionBook>"#).unwrap();
        assert_eq!(first, second);
        assert!(first.starts_with(b"PK\x03\x04"));
        assert!(first
            .windows(b"mimetype".len())
            .any(|window| window == b"mimetype"));
        assert!(first
            .windows(b"application/epub+zip".len())
            .any(|window| window == b"application/epub+zip"));
    }

    #[test]
    fn fb2_conversion_retains_sections_toc_and_embedded_image() {
        let source = br##"<?xml version="1.0"?>
            <FictionBook xmlns:l="urn:fb"><description><title-info><book-title>Illustrated</book-title></title-info></description>
            <body><section><title>One</title><p>Hello</p><image l:href="#cover"/></section><section><title>Two</title><p>World</p></section></body>
            <binary id="cover" content-type="image/png">AQID</binary></FictionBook>"##;
        let epub = convert_to_internal_epub(SupportedFormat::Fb2, source).unwrap();
        assert!(epub
            .windows(b"chapter-0001.xhtml".len())
            .any(|window| window == b"chapter-0001.xhtml"));
        assert!(epub
            .windows(b"chapter-0002.xhtml".len())
            .any(|window| window == b"chapter-0002.xhtml"));
        assert!(epub
            .windows(b"Images/cover.png".len())
            .any(|window| window == b"Images/cover.png"));
        assert!(epub.windows(3).any(|window| window == [1, 2, 3]));
    }

    #[test]
    fn hashes_are_stable_and_lowercase() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn reader_hashes_without_loading_the_whole_stream() {
        let mut reader = Cursor::new(b"abc".to_vec());
        assert_eq!(sha256_reader(&mut reader).unwrap(), sha256_hex(b"abc"));
    }

    #[test]
    fn incremental_hasher_can_checkpoint_and_reset() {
        let mut hasher = ContentHasher::new();
        hasher.update(b"a");
        assert_ne!(hasher.finalize_hex(), sha256_hex(b"abc"));
        hasher.update(b"bc");
        assert_eq!(hasher.finalize_hex(), sha256_hex(b"abc"));
        hasher.reset();
        assert_eq!(hasher.finalize_hex(), sha256_hex(b""));
    }

    #[test]
    fn cache_key_includes_converter_version() {
        assert_eq!(
            converter_cache_key("hash", "converter-1"),
            "hash:converter-1"
        );
    }

    #[test]
    fn detects_archive_signatures_and_rejects_mismatch() {
        assert_eq!(detect_archive_kind(b"PK\x03\x04rest"), ArchiveKind::Zip);
        assert_eq!(
            detect_archive_kind(b"Rar!\x1a\x07\x01\x00rest"),
            ArchiveKind::Rar
        );
        assert_eq!(
            detect_archive_kind(b"7z\xbc\xaf\x27\x1crest"),
            ArchiveKind::SevenZip
        );
        assert_eq!(detect_archive_kind(b"not-an-archive"), ArchiveKind::Unknown);
        assert_eq!(
            detect_format("comic.cbz", b"PK\x03\x04rest"),
            Some(SupportedFormat::Cbz)
        );
        assert_eq!(detect_format("comic.cbz", b"Rar!\x1a\x07\x00"), None);
        assert_eq!(
            detect_format("book.pdf", b"%PDF-1.7"),
            Some(SupportedFormat::Pdf)
        );
        assert_eq!(detect_format("book.pdf", b"PK\x03\x04"), None);
    }

    #[test]
    fn format_sniffing_requires_complete_magic_and_the_final_extension() {
        let complete_headers: [(&str, &[u8], SupportedFormat); 4] = [
            ("book.epub", b"PK\x05\x06", SupportedFormat::Epub),
            ("book.kepub", b"PK\x07\x08", SupportedFormat::Kepub),
            ("comic.cbz", b"PK\x03\x04", SupportedFormat::Cbz),
            ("comic.cbr", b"Rar!\x1a\x07\x00", SupportedFormat::Cbr),
        ];
        for (filename, header, format) in complete_headers {
            assert_eq!(detect_format(filename, header), Some(format));
            assert_eq!(
                detect_format(filename, &header[..header.len() - 1]),
                None,
                "{filename} must not accept a truncated magic header"
            );
        }
        assert_eq!(
            detect_format("book.epub.exe", b"PK\x03\x04"),
            None,
            "only the final extension selects a format"
        );
        assert_eq!(
            format_from_filename_ref("archive.backup.cb7"),
            Some(SupportedFormat::Cb7)
        );
    }

    #[test]
    fn validates_filenames_and_sanitizes_untrusted_input() {
        assert!(validate_filename("A book.epub").is_ok());
        assert_eq!(
            validate_filename("../secret.epub"),
            Err(FilenameSafetyError::PathSeparator)
        );
        assert_eq!(
            validate_filename("CON.txt"),
            Err(FilenameSafetyError::ReservedDeviceName)
        );
        assert_eq!(
            validate_filename("book.epub."),
            Err(FilenameSafetyError::ReservedCharacter)
        );
        assert_eq!(
            validate_filename("book.epub "),
            Err(FilenameSafetyError::ReservedCharacter)
        );
        assert_eq!(sanitize_filename("../bad:name?.epub"), "bad_name_.epub");
        assert_eq!(sanitize_filename("..."), "untitled");
        assert!(sanitize_filename(&"a".repeat(300)).len() <= MAX_FILENAME_BYTES);
    }

    #[test]
    fn filename_byte_limits_preserve_utf8_boundaries() {
        let exact_limit = "a".repeat(MAX_FILENAME_BYTES);
        assert!(validate_filename(&exact_limit).is_ok());
        assert_eq!(
            validate_filename(&"a".repeat(MAX_FILENAME_BYTES + 1)),
            Err(FilenameSafetyError::TooLong)
        );

        let emoji_over_limit = "😀".repeat(64);
        let sanitized = sanitize_filename(&emoji_over_limit);
        assert_eq!(sanitized, "😀".repeat(63));
        assert_eq!(sanitized.len(), 252);
        assert!(sanitized.is_char_boundary(sanitized.len()));
        assert!(validate_filename("Páprïa 水墨.epub").is_ok());
    }

    #[test]
    fn rejects_archive_path_traversal_and_absolute_names() {
        assert!(validate_archive_entry_path("images/page-1.jpg").is_ok());
        assert_eq!(
            validate_archive_entry_path("../outside.txt"),
            Err(ArchiveSafetyError::PathTraversal)
        );
        assert_eq!(
            validate_archive_entry_path("/outside.txt"),
            Err(ArchiveSafetyError::AbsolutePath)
        );
        assert_eq!(
            validate_archive_entry_path("C:\\outside.txt"),
            Err(ArchiveSafetyError::AbsolutePath)
        );
        assert_eq!(
            validate_archive_entry_path("folder\\outside.txt"),
            Err(ArchiveSafetyError::InvalidPathSeparator)
        );
    }

    #[test]
    fn archive_paths_enforce_control_and_byte_boundaries() {
        assert!(validate_archive_entry_path(&"a".repeat(MAX_ARCHIVE_PATH_BYTES)).is_ok());
        assert_eq!(
            validate_archive_entry_path(&"a".repeat(MAX_ARCHIVE_PATH_BYTES + 1)),
            Err(ArchiveSafetyError::PathTooLong)
        );
        for (path, error) in [
            ("", ArchiveSafetyError::EmptyPath),
            (".", ArchiveSafetyError::PathTraversal),
            ("pages/./001.jpg", ArchiveSafetyError::PathTraversal),
            ("pages/\0hidden.jpg", ArchiveSafetyError::ControlCharacter),
            ("z:relative.jpg", ArchiveSafetyError::AbsolutePath),
        ] {
            assert_eq!(validate_archive_entry_path(path), Err(error));
        }
        assert!(validate_archive_entry_path("目录/水墨-001.jpg").is_ok());
    }

    #[test]
    fn enforces_archive_entry_count_size_and_ratio_limits() {
        let limits = ArchiveLimits {
            max_entries: 2,
            max_uncompressed_bytes: 100,
            max_entry_uncompressed_bytes: 80,
            max_compression_ratio: 10,
        };
        let entries = vec![ArchiveEntry {
            path: "page.jpg".to_owned(),
            compressed_size: 10,
            uncompressed_size: 80,
            compressed_size_known: true,
        }];
        let report = inspect_archive_entries(&entries, limits).unwrap();
        assert_eq!(report.entry_count, 1);
        assert_eq!(report.uncompressed_bytes, 80);

        let too_many = vec![entries[0].clone(), entries[0].clone(), entries[0].clone()];
        assert_eq!(
            validate_archive_entries(&too_many, limits),
            Err(ArchiveSafetyError::TooManyEntries)
        );
        let too_large = vec![ArchiveEntry {
            path: "huge.bin".to_owned(),
            compressed_size: 10,
            uncompressed_size: 81,
            compressed_size_known: true,
        }];
        assert_eq!(
            validate_archive_entries(&too_large, limits),
            Err(ArchiveSafetyError::EntrySizeExceeded)
        );
        let bomb = vec![ArchiveEntry {
            path: "bomb.bin".to_owned(),
            compressed_size: 1,
            uncompressed_size: 11,
            compressed_size_known: true,
        }];
        assert_eq!(
            validate_archive_entries(&bomb, limits),
            Err(ArchiveSafetyError::CompressionRatioExceeded)
        );

        // A metadata-only caller cannot claim a safe ratio when packed size is
        // unknown. The real 7z inspector uses its trusted folder pack size
        // before it returns a member; this lower-level entry point fails
        // closed instead of accepting the old bypass.
        let unknown_packed_size = vec![ArchiveEntry {
            path: "7z-page.jpg".to_owned(),
            compressed_size: 0,
            uncompressed_size: 80,
            compressed_size_known: false,
        }];
        assert_eq!(
            validate_archive_entries(&unknown_packed_size, limits),
            Err(ArchiveSafetyError::CompressedSizeUnavailable)
        );

        let known_zero_packed_size = vec![ArchiveEntry {
            path: "known-zero.bin".to_owned(),
            compressed_size: 0,
            uncompressed_size: 1,
            compressed_size_known: true,
        }];
        assert_eq!(
            validate_archive_entries(&known_zero_packed_size, limits),
            Err(ArchiveSafetyError::CompressionRatioExceeded)
        );
    }

    #[test]
    fn archive_metadata_accepts_exact_limits_and_rejects_zero_configuration() {
        let limits = ArchiveLimits {
            max_entries: 2,
            max_uncompressed_bytes: 100,
            max_entry_uncompressed_bytes: 50,
            max_compression_ratio: 10,
        };
        let entries = vec![
            ArchiveEntry {
                path: "pages/001.jpg".to_owned(),
                compressed_size: 5,
                uncompressed_size: 50,
                compressed_size_known: true,
            },
            ArchiveEntry {
                path: "pages/002.jpg".to_owned(),
                compressed_size: 5,
                uncompressed_size: 50,
                compressed_size_known: true,
            },
        ];
        assert_eq!(
            inspect_archive_entries(&entries, limits),
            Ok(ArchiveInspection {
                entry_count: 2,
                compressed_bytes: 10,
                uncompressed_bytes: 100,
            })
        );

        for invalid_limits in [
            ArchiveLimits {
                max_entries: 0,
                ..limits
            },
            ArchiveLimits {
                max_uncompressed_bytes: 0,
                ..limits
            },
            ArchiveLimits {
                max_entry_uncompressed_bytes: 0,
                ..limits
            },
            ArchiveLimits {
                max_compression_ratio: 0,
                ..limits
            },
        ] {
            assert_eq!(
                inspect_archive_entries(&entries, invalid_limits),
                Err(ArchiveSafetyError::InvalidLimits)
            );
        }
    }

    #[test]
    fn inspects_real_zip_metadata_and_rejects_boundary_violations() {
        let valid = make_stored_zip(&[("pages/001.jpg", b"abc"), ("pages/002.jpg", b"defg")]);
        let report = inspect_bytes(valid, test_limits()).unwrap();
        assert_eq!(report.kind, ArchiveKind::Zip);
        assert_eq!(report.compressed_bytes, 7);
        assert_eq!(report.uncompressed_bytes, 7);
        assert_eq!(
            report.entries,
            vec![
                ArchiveEntry {
                    path: "pages/001.jpg".to_owned(),
                    compressed_size: 3,
                    uncompressed_size: 3,
                    compressed_size_known: true,
                },
                ArchiveEntry {
                    path: "pages/002.jpg".to_owned(),
                    compressed_size: 4,
                    uncompressed_size: 4,
                    compressed_size_known: true,
                },
            ]
        );

        let traversal = make_stored_zip(&[("../escape.jpg", b"x")]);
        assert_eq!(
            inspect_bytes(traversal, test_limits()),
            Err(ArchiveSafetyError::PathTraversal)
        );
        let duplicate = make_stored_zip(&[("same.jpg", b"x"), ("same.jpg", b"y")]);
        assert_eq!(
            inspect_bytes(duplicate, test_limits()),
            Err(ArchiveSafetyError::DuplicatePath)
        );

        let mut encrypted = make_stored_zip(&[("page.jpg", b"x")]);
        let central = encrypted
            .windows(4)
            .position(|window| window == b"PK\x01\x02")
            .unwrap();
        encrypted[central + 8] = 1;
        encrypted[central + 9] = 0;
        assert_eq!(
            inspect_bytes(encrypted, test_limits()),
            Err(ArchiveSafetyError::EncryptedArchive)
        );
    }

    #[test]
    fn inspects_real_rar4_container_and_rejects_rar5() {
        let report = inspect_bytes(make_empty_rar4(), test_limits()).unwrap();
        assert_eq!(report.kind, ArchiveKind::Rar);
        assert!(report.entries.is_empty());
        assert_eq!(report.compressed_bytes, 0);

        assert_eq!(
            inspect_bytes(b"Rar!\x1a\x07\x01\x00".to_vec(), test_limits()),
            Err(ArchiveSafetyError::UnsupportedArchive)
        );
    }

    #[test]
    fn inspects_7z_with_trusted_group_ratio_and_never_allows_unknown_member_size() {
        let valid = make_minimal_7z("page.jpg", 5, 80);
        let report = inspect_bytes(valid, test_limits()).unwrap();
        assert_eq!(report.kind, ArchiveKind::SevenZip);
        assert_eq!(report.compressed_bytes, 5);
        assert_eq!(report.uncompressed_bytes, 80);
        assert_eq!(report.entries.len(), 1);
        assert_eq!(report.entries[0].path, "page.jpg");
        assert_eq!(report.entries[0].compressed_size, 5);
        assert!(report.entries[0].compressed_size_known);

        let ratio_bomb = make_minimal_7z("bomb.jpg", 1, 101);
        assert_eq!(
            inspect_bytes(ratio_bomb, test_limits()),
            Err(ArchiveSafetyError::CompressionRatioExceeded)
        );

        let traversal = make_minimal_7z("../escape.jpg", 5, 10);
        assert_eq!(
            inspect_bytes(traversal, test_limits()),
            Err(ArchiveSafetyError::PathTraversal)
        );
    }

    #[test]
    fn archive_reader_rejects_out_of_range_and_invalid_callback_responses() {
        struct OverlongSource;

        impl ArchiveByteSource for OverlongSource {
            fn length(&self) -> u64 {
                8
            }

            fn read_at(&self, _: u64, length: u32) -> Result<Vec<u8>, ArchiveSourceError> {
                Ok(vec![0; length as usize + 1])
            }
        }

        struct FailingSource;

        impl ArchiveByteSource for FailingSource {
            fn length(&self) -> u64 {
                8
            }

            fn read_at(&self, _: u64, _: u32) -> Result<Vec<u8>, ArchiveSourceError> {
                Err(ArchiveSourceError::ReadFailed)
            }
        }

        let source = MemorySource(vec![0; 8]);
        let reader = BoundedArchiveReader::new(&source);
        assert_eq!(
            reader.read_exact(0, MAX_ARCHIVE_SOURCE_READ_BYTES + 1),
            Err(ArchiveSafetyError::InvalidArchive)
        );
        assert_eq!(
            reader.read_exact(u64::MAX, 1),
            Err(ArchiveSafetyError::InvalidArchive)
        );
        assert_eq!(
            BoundedArchiveReader::new(&OverlongSource).read_exact(0, 1),
            Err(ArchiveSafetyError::InvalidArchive)
        );
        assert_eq!(
            BoundedArchiveReader::new(&FailingSource).read_exact(0, 1),
            Err(ArchiveSafetyError::SourceReadFailed)
        );
    }

    #[test]
    fn converts_fb2_markup_without_executing_html() {
        let html = convert_fb2_to_html(
            "<FictionBook><body><title>Title</title><p>A &amp; B</p></body></FictionBook>",
        )
        .unwrap();
        assert!(html.contains("Title"));
        assert!(html.contains("A &amp; B"));
        assert!(!html.contains("<script"));
    }

    #[test]
    fn rejects_invalid_fb2_binary_ids_and_duplicate_ids() {
        let traversal = br#"<FictionBook><body><p>text</p></body><binary id="../escape" content-type="image/png">AQID</binary></FictionBook>"#;
        assert_eq!(
            convert_to_internal_epub(SupportedFormat::Fb2, traversal),
            Err(ConversionError::InvalidContainer)
        );

        let duplicate = br#"<FictionBook><body><p>text</p></body><binary id="cover">AQID</binary><binary id="cover">BAUG</binary></FictionBook>"#;
        assert_eq!(
            convert_to_internal_epub(SupportedFormat::Fb2, duplicate),
            Err(ConversionError::InvalidContainer)
        );
    }

    #[test]
    fn base64_decoder_rejects_malformed_padding() {
        assert_eq!(decode_base64(b"AQID"), Some(vec![1, 2, 3]));
        assert_eq!(decode_base64(b"AQI="), Some(vec![1, 2]));
        assert_eq!(decode_base64(b"AQ=="), Some(vec![1]));
        assert!(decode_base64(b"A===").is_none());
        assert!(decode_base64(b"AA=A").is_none());
        assert!(decode_base64(b"====").is_none());
        assert!(decode_base64(b"AQ==BA==").is_none());
    }

    #[test]
    fn seven_zip_name_decoding_requires_valid_complete_utf16() {
        let expected = "目录/水墨😀.jpg";
        let valid: Vec<u8> = expected
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .chain([0, 0])
            .collect();
        assert_eq!(
            parse_7z_utf16_names(&valid, 1),
            Ok(vec![expected.to_owned()])
        );
        assert_eq!(
            parse_7z_utf16_names(&[0], 1),
            Err(ArchiveSafetyError::InvalidArchive),
            "UTF-16 always uses whole 16-bit units"
        );
        assert_eq!(
            parse_7z_utf16_names(&[0, 0xd8, 0, 0], 1),
            Err(ArchiveSafetyError::InvalidArchive),
            "unpaired surrogates are not valid UTF-16 names"
        );
        assert_eq!(
            parse_7z_utf16_names(&[b'a', 0], 1),
            Err(ArchiveSafetyError::InvalidArchive),
            "each name must be NUL terminated"
        );
        assert_eq!(
            parse_7z_utf16_names(&valid, 2),
            Err(ArchiveSafetyError::InvalidArchive),
            "the declared file count must match the encoded names"
        );
    }

    #[test]
    fn decodes_uncompressed_palmdoc_records_through_libmobi() {
        let mut input = vec![0_u8; 78 + 2 * 8 + 16 + 5];
        input[60..64].copy_from_slice(b"BOOK");
        input[64..68].copy_from_slice(b"MOBI");
        input[76..78].copy_from_slice(&2_u16.to_be_bytes());
        let first_record = 78 + 2 * 8;
        input[78..82].copy_from_slice(&(first_record as u32).to_be_bytes());
        input[86..90].copy_from_slice(&((first_record + 16) as u32).to_be_bytes());
        input[first_record..first_record + 2].copy_from_slice(&1_u16.to_be_bytes());
        input[first_record + 4..first_record + 8].copy_from_slice(&5_u32.to_be_bytes());
        input[first_record + 8..first_record + 10].copy_from_slice(&1_u16.to_be_bytes());
        input[first_record + 10..first_record + 12].copy_from_slice(&4096_u16.to_be_bytes());
        input[first_record + 16..first_record + 21].copy_from_slice(b"hello");
        assert_eq!(extract_mobi_family_content_ref(&input).unwrap().0, "hello");

        input[first_record + 12..first_record + 14].copy_from_slice(&1_u16.to_be_bytes());
        assert!(matches!(
            extract_mobi_family_content_ref(&input),
            Err(ConversionError::Encrypted)
        ));
    }

    #[test]
    fn unsupported_formats_do_not_enter_text_conversion() {
        assert_eq!(
            convert_to_internal_html(SupportedFormat::Pdf, b"%PDF-1.7"),
            Err(ConversionError::UnsupportedFormat)
        );
    }

    #[test]
    fn palm_doc_offsets_cannot_point_into_the_record_table() {
        let mut input = vec![0_u8; 78 + 2 * 8 + 16];
        input[76..78].copy_from_slice(&2_u16.to_be_bytes());
        input[78..82].copy_from_slice(&0_u32.to_be_bytes());
        input[86..90].copy_from_slice(&((78 + 2 * 8 + 16) as u32).to_be_bytes());
        assert!(matches!(
            extract_mobi_family_content_ref(&input),
            Err(ConversionError::InvalidContainer)
        ));
    }

    #[test]
    fn palm_doc_text_records_cannot_exceed_available_records() {
        let mut input = vec![0_u8; 78 + 2 * 8 + 16 + 5];
        input[76..78].copy_from_slice(&2_u16.to_be_bytes());
        let first_record = 78 + 2 * 8;
        input[78..82].copy_from_slice(&(first_record as u32).to_be_bytes());
        input[86..90].copy_from_slice(&((first_record + 16) as u32).to_be_bytes());
        input[first_record..first_record + 2].copy_from_slice(&1_u16.to_be_bytes());
        input[first_record + 8..first_record + 10].copy_from_slice(&2_u16.to_be_bytes());
        input[first_record + 16..first_record + 21].copy_from_slice(b"hello");

        assert!(matches!(
            extract_mobi_family_content_ref(&input),
            Err(ConversionError::InvalidContainer)
        ));
    }

    #[test]
    fn supported_format_contract_matrix_is_exact() {
        let cases = [
            (
                "EPUB",
                SupportedFormat::Epub,
                ReaderStrategy::ReadiumEpub,
                false,
                None,
            ),
            (
                "kepub",
                SupportedFormat::Kepub,
                ReaderStrategy::ReadiumEpub,
                false,
                None,
            ),
            (
                "mobi",
                SupportedFormat::Mobi,
                ReaderStrategy::ConvertToEpub,
                false,
                None,
            ),
            (
                "azw",
                SupportedFormat::Azw,
                ReaderStrategy::ConvertToEpub,
                false,
                None,
            ),
            (
                "azw3",
                SupportedFormat::Azw3,
                ReaderStrategy::ConvertToEpub,
                false,
                None,
            ),
            (
                "fb2",
                SupportedFormat::Fb2,
                ReaderStrategy::ConvertToEpub,
                false,
                None,
            ),
            (
                "pdf",
                SupportedFormat::Pdf,
                ReaderStrategy::ReadiumPdf,
                false,
                None,
            ),
            (
                "cbz",
                SupportedFormat::Cbz,
                ReaderStrategy::ComicArchive,
                false,
                Some(ArchiveKind::Zip),
            ),
            (
                "cbr",
                SupportedFormat::Cbr,
                ReaderStrategy::ComicArchive,
                false,
                Some(ArchiveKind::Rar),
            ),
            (
                "cb7",
                SupportedFormat::Cb7,
                ReaderStrategy::ComicArchive,
                false,
                Some(ArchiveKind::SevenZip),
            ),
            (
                "m4b",
                SupportedFormat::M4b,
                ReaderStrategy::Audio,
                true,
                None,
            ),
            (
                "m4a",
                SupportedFormat::M4a,
                ReaderStrategy::Audio,
                true,
                None,
            ),
            (
                "mp3",
                SupportedFormat::Mp3,
                ReaderStrategy::Audio,
                true,
                None,
            ),
            (
                "opus",
                SupportedFormat::Opus,
                ReaderStrategy::Audio,
                true,
                None,
            ),
            (
                "ogg",
                SupportedFormat::Ogg,
                ReaderStrategy::Audio,
                true,
                None,
            ),
            (
                "flac",
                SupportedFormat::Flac,
                ReaderStrategy::Audio,
                true,
                None,
            ),
        ];

        for (extension, format, strategy, is_audio, archive_kind) in cases {
            assert_eq!(SupportedFormat::from_extension(extension), Some(format));
            assert_eq!(
                format_from_filename_ref(&format!("book.{extension}")),
                Some(format)
            );
            assert_eq!(reader_strategy(format), strategy);
            assert_eq!(format.is_audio(), is_audio);
            assert_eq!(format.archive_kind(), archive_kind);
        }
    }

    #[test]
    fn stream_hashing_handles_empty_fragmented_and_failed_reads() {
        struct FragmentedReader {
            bytes: Vec<u8>,
            offset: usize,
            fragment_size: usize,
        }

        impl Read for FragmentedReader {
            fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
                if self.offset == self.bytes.len() {
                    return Ok(0);
                }
                let count = self
                    .fragment_size
                    .min(buffer.len())
                    .min(self.bytes.len() - self.offset);
                buffer[..count].copy_from_slice(&self.bytes[self.offset..self.offset + count]);
                self.offset += count;
                Ok(count)
            }
        }

        struct FailingReader(bool);

        impl Read for FailingReader {
            fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
                if self.0 {
                    return Err(io::Error::other("injected read failure"));
                }
                buffer[..2].copy_from_slice(b"ab");
                self.0 = true;
                Ok(2)
            }
        }

        let mut empty = Cursor::new(Vec::new());
        assert_eq!(sha256_reader(&mut empty).unwrap(), sha256_hex(b""));

        let mut fragmented = FragmentedReader {
            bytes: b"fragmented stream input".to_vec(),
            offset: 0,
            fragment_size: 3,
        };
        assert_eq!(
            sha256_reader(&mut fragmented).unwrap(),
            sha256_hex(b"fragmented stream input")
        );

        let error = sha256_reader(&mut FailingReader(false)).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Other);
    }

    #[test]
    fn archive_inspection_rejects_empty_truncated_and_wrong_signatures() {
        let cases: [(&str, &[u8], ArchiveSafetyError); 5] = [
            ("empty", b"", ArchiveSafetyError::InvalidArchive),
            (
                "truncated ZIP",
                b"PK\x03\x04",
                ArchiveSafetyError::InvalidArchive,
            ),
            (
                "truncated RAR4",
                b"Rar!\x1a\x07\x00",
                ArchiveSafetyError::UnsupportedArchive,
            ),
            (
                "truncated 7z",
                b"7z\xbc\xaf\x27\x1c",
                ArchiveSafetyError::InvalidArchive,
            ),
            (
                "wrong signature",
                b"not-an-archive",
                ArchiveSafetyError::InvalidArchive,
            ),
        ];

        for (case, bytes, error) in cases {
            assert_eq!(
                inspect_bytes(bytes.to_vec(), test_limits()),
                Err(error),
                "{case} must fail closed"
            );
        }
    }

    #[test]
    fn filename_reserved_character_and_device_name_matrix_is_fail_closed() {
        for character in ['<', '>', ':', '"', '|', '?', '*'] {
            let filename = format!("book{character}.epub");
            assert_eq!(
                validate_filename(&filename),
                Err(FilenameSafetyError::ReservedCharacter),
                "{character:?} must be rejected"
            );
        }

        for filename in [
            "PRN",
            "aux.txt",
            "NUL.epub",
            "com1",
            "COM9.mobi",
            "lpt1",
            "LPT9.fb2",
        ] {
            assert_eq!(
                validate_filename(filename),
                Err(FilenameSafetyError::ReservedDeviceName),
                "{filename} must not depend on platform filesystem behavior"
            );
        }

        assert_eq!(sanitize_filename("C:\\uploads\\CON.epub"), "_CON.epub");
        assert!(validate_filename("封面-😀.epub").is_ok());
    }

    #[test]
    fn zip_metadata_rejects_truncation_invalid_encoding_and_name_mismatch() {
        let valid = make_stored_zip(&[("page.jpg", b"x")]);

        let mut truncated = valid.clone();
        truncated.pop();
        assert_eq!(
            inspect_bytes(truncated, test_limits()),
            Err(ArchiveSafetyError::InvalidArchive)
        );

        let central = valid
            .windows(4)
            .position(|window| window == b"PK\x01\x02")
            .unwrap();
        let mut invalid_utf8 = valid.clone();
        invalid_utf8[30] = 0xff;
        invalid_utf8[central + 46] = 0xff;
        assert_eq!(
            inspect_bytes(invalid_utf8, test_limits()),
            Err(ArchiveSafetyError::InvalidArchive)
        );

        let mut mismatched_names = valid;
        mismatched_names[30] = b'P';
        assert_eq!(
            inspect_bytes(mismatched_names, test_limits()),
            Err(ArchiveSafetyError::InvalidArchive)
        );
    }

    #[test]
    fn trusted_7z_ratio_accepts_the_limit_and_rejects_one_byte_above() {
        let limits = ArchiveLimits {
            max_entries: 1,
            max_uncompressed_bytes: 101,
            max_entry_uncompressed_bytes: 101,
            max_compression_ratio: 10,
        };
        let exact = inspect_bytes(make_minimal_7z("page.jpg", 10, 100), limits).unwrap();
        assert_eq!(exact.compressed_bytes, 10);
        assert_eq!(exact.uncompressed_bytes, 100);

        assert_eq!(
            inspect_bytes(make_minimal_7z("bomb.jpg", 10, 101), limits),
            Err(ArchiveSafetyError::CompressionRatioExceeded)
        );
    }

    #[test]
    fn mobi_family_conversion_rejects_empty_and_truncated_inputs() {
        for format in [
            SupportedFormat::Mobi,
            SupportedFormat::Azw,
            SupportedFormat::Azw3,
        ] {
            assert_eq!(
                convert_to_internal_html(format, b""),
                Err(ConversionError::InvalidContainer),
                "{format:?} empty input"
            );
            assert_eq!(
                convert_to_internal_epub(format, b"BOOK"),
                Err(ConversionError::InvalidContainer),
                "{format:?} truncated input"
            );
        }
    }

    #[test]
    fn fb2_and_epub_conversion_boundaries_are_explicit() {
        for input in [
            b"".as_slice(),
            b"<FictionBook><body><p>text</p></body><binary id=\"cover\">AQID".as_slice(),
            b"<FictionBook><body></body></FictionBook>".as_slice(),
        ] {
            assert_eq!(
                convert_to_internal_epub(SupportedFormat::Fb2, input),
                Err(ConversionError::InvalidContainer)
            );
        }
        assert_eq!(
            convert_to_internal_html(SupportedFormat::Fb2, b"\xff"),
            Err(ConversionError::InvalidUtf8)
        );
        assert_eq!(
            convert_to_internal_epub(SupportedFormat::Epub, b"PK\x03\x04"),
            Err(ConversionError::UnsupportedFormat)
        );

        let epub = convert_to_internal_epub(
            SupportedFormat::Fb2,
            b"<FictionBook><body><section><p>text</p></section></body></FictionBook>",
        )
        .unwrap();
        let inspection = inspect_bytes(epub, ArchiveLimits::default()).unwrap();
        assert_eq!(inspection.kind, ArchiveKind::Zip);
        assert!(inspection
            .entries
            .iter()
            .any(|entry| entry.path == "mimetype"));
        assert!(inspection
            .entries
            .iter()
            .any(|entry| entry.path == "OEBPS/chapter-0001.xhtml"));
    }
}
