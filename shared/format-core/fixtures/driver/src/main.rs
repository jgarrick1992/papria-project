use std::env;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use papria_format_core::{
    convert_to_internal_epub, default_archive_limits, detect_format, inspect_comic_archive,
    sha256_reader, ArchiveByteSource, ArchiveKind, ArchiveSourceError, SupportedFormat,
};

const LARGE_FIXTURE_BYTES: u64 = 64 * 1024 * 1024 + 1;

#[derive(Clone, Copy)]
struct FixtureSpec {
    name: &'static str,
    extension: &'static str,
    format: SupportedFormat,
    malformed_detection: bool,
    conversion: bool,
}

const SPECS: [FixtureSpec; 16] = [
    FixtureSpec { name: "epub", extension: "epub", format: SupportedFormat::Epub, malformed_detection: false, conversion: false },
    FixtureSpec { name: "kepub", extension: "kepub", format: SupportedFormat::Kepub, malformed_detection: false, conversion: false },
    FixtureSpec { name: "mobi", extension: "mobi", format: SupportedFormat::Mobi, malformed_detection: true, conversion: true },
    FixtureSpec { name: "azw", extension: "azw", format: SupportedFormat::Azw, malformed_detection: true, conversion: true },
    FixtureSpec { name: "azw3", extension: "azw3", format: SupportedFormat::Azw3, malformed_detection: true, conversion: true },
    FixtureSpec { name: "fb2", extension: "fb2", format: SupportedFormat::Fb2, malformed_detection: true, conversion: true },
    FixtureSpec { name: "pdf", extension: "pdf", format: SupportedFormat::Pdf, malformed_detection: false, conversion: false },
    FixtureSpec { name: "cbz", extension: "cbz", format: SupportedFormat::Cbz, malformed_detection: false, conversion: false },
    FixtureSpec { name: "cbr", extension: "cbr", format: SupportedFormat::Cbr, malformed_detection: false, conversion: false },
    FixtureSpec { name: "cb7", extension: "cb7", format: SupportedFormat::Cb7, malformed_detection: false, conversion: false },
    FixtureSpec { name: "m4b", extension: "m4b", format: SupportedFormat::M4b, malformed_detection: true, conversion: false },
    FixtureSpec { name: "m4a", extension: "m4a", format: SupportedFormat::M4a, malformed_detection: true, conversion: false },
    FixtureSpec { name: "mp3", extension: "mp3", format: SupportedFormat::Mp3, malformed_detection: true, conversion: false },
    FixtureSpec { name: "opus", extension: "opus", format: SupportedFormat::Opus, malformed_detection: true, conversion: false },
    FixtureSpec { name: "ogg", extension: "ogg", format: SupportedFormat::Ogg, malformed_detection: true, conversion: false },
    FixtureSpec { name: "flac", extension: "flac", format: SupportedFormat::Flac, malformed_detection: true, conversion: false },
];

struct FileSource {
    path: PathBuf,
}

impl ArchiveByteSource for FileSource {
    fn length(&self) -> u64 {
        fs::metadata(&self.path).unwrap_or_else(|error| panic!("{}: {error}", self.path.display())).len()
    }

    fn read_at(&self, offset: u64, length: u32) -> Result<Vec<u8>, ArchiveSourceError> {
        let mut file = File::open(&self.path).map_err(|_| ArchiveSourceError::ReadFailed)?;
        file.seek(SeekFrom::Start(offset)).map_err(|_| ArchiveSourceError::ReadFailed)?;
        let mut bytes = vec![0_u8; length as usize];
        file.read_exact(&mut bytes).map_err(|_| ArchiveSourceError::ReadFailed)?;
        Ok(bytes)
    }
}

fn read_header(path: &Path) -> Vec<u8> {
    let mut file = File::open(path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    let mut header = vec![0_u8; 4096];
    let bytes = file.read(&mut header).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    header.truncate(bytes);
    header
}

fn assert_detection(path: &Path, expected: Option<SupportedFormat>) {
    let filename = path.file_name().unwrap().to_string_lossy().into_owned();
    assert_eq!(
        detect_format(filename, read_header(path)),
        expected,
        "unexpected detection result for {}",
        path.display(),
    );
}

fn special_file(directory: &Path, extension: &str) -> PathBuf {
    let expected_suffix = format!(".{extension}");
    fs::read_dir(directory)
        .unwrap_or_else(|error| panic!("{}: {error}", directory.display()))
        .map(|item| item.unwrap_or_else(|error| panic!("{}: {error}", directory.display())).path())
        .find(|path| {
            let name = path.file_name().unwrap().to_string_lossy();
            name.starts_with("Páprïa 水墨:") && name.ends_with(&expected_suffix)
        })
        .unwrap_or_else(|| panic!("{}: missing special filename", directory.display()))
}

fn main() {
    let root = env::args().nth(1).expect("usage: fixture-driver <generated-fixture-root>");
    let root = Path::new(&root);
    for spec in SPECS {
        let directory = root.join("assets").join(spec.name);
        let normal = directory.join(format!("normal.{}", spec.extension));
        let malformed = directory.join(format!("malformed.{}", spec.extension));
        let special = special_file(&directory, spec.extension);
        let large = root.join("large").join(spec.name).join(format!("large.{}", spec.extension));

        assert_detection(&normal, Some(spec.format));
        assert_detection(&special, Some(spec.format));
        assert_detection(&malformed, spec.malformed_detection.then_some(spec.format));

        assert_eq!(fs::metadata(&large).unwrap().len(), LARGE_FIXTURE_BYTES, "{} has incorrect logical size", large.display());
        assert_detection(&large, Some(spec.format));
        if matches!(spec.format, SupportedFormat::Pdf | SupportedFormat::Cbz | SupportedFormat::Cbr | SupportedFormat::Cb7) {
            let mut stream = File::open(&large).unwrap();
            let digest = sha256_reader(&mut stream).unwrap();
            assert_eq!(digest.len(), 64, "{} did not stream through SHA-256", large.display());
            assert!(digest.bytes().all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()));
        }

        if matches!(spec.format, SupportedFormat::Cbz | SupportedFormat::Cbr | SupportedFormat::Cb7) {
            let expected_kind = match spec.format {
                SupportedFormat::Cbz => ArchiveKind::Zip,
                SupportedFormat::Cbr => ArchiveKind::Rar,
                SupportedFormat::Cb7 => ArchiveKind::SevenZip,
                _ => unreachable!(),
            };
            for path in [&normal, &special] {
                let inspection = inspect_comic_archive(
                    Box::new(FileSource { path: path.clone() }),
                    default_archive_limits(),
                ).unwrap_or_else(|error| panic!("{} should be inspectable: {error}", path.display()));
                assert_eq!(inspection.kind, expected_kind, "{} archive kind mismatch", path.display());
            }
            assert!(inspect_comic_archive(
                Box::new(FileSource { path: malformed.clone() }),
                default_archive_limits(),
            ).is_err(), "{} must be rejected by archive inspection", malformed.display());
        }

        if spec.conversion {
            let normal_epub = convert_to_internal_epub(spec.format, fs::read(&normal).unwrap())
                .unwrap_or_else(|error| panic!("{} should convert: {error}", normal.display()));
            assert!(normal_epub.starts_with(b"PK\x03\x04"), "{} did not produce internal EPUB", normal.display());
            let special_epub = convert_to_internal_epub(spec.format, fs::read(&special).unwrap())
                .unwrap_or_else(|error| panic!("{} should convert: {error}", special.display()));
            assert!(special_epub.starts_with(b"PK\x03\x04"), "{} did not produce internal EPUB", special.display());
            assert!(convert_to_internal_epub(spec.format, fs::read(&malformed).unwrap()).is_err(), "{} must be rejected by conversion", malformed.display());
        }
    }
    println!("format fixture driver: ok (16 formats, detection, conversion, streamed large cases)");
}
