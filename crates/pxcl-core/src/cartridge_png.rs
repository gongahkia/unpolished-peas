use serde::{Deserialize, Serialize};

use crate::cartridge::CARTRIDGE_CAPACITY_BYTES;

const PNG_SIGNATURE: [u8; 8] = [137, 80, 78, 71, 13, 10, 26, 10];
const MAX_PNG_BYTES: usize = 8 * 1024 * 1024;
const WIDTH: usize = 320;
const HEIGHT: usize = 240;
const PALETTE: [[u8; 3]; 8] = [
    [23, 20, 31],
    [41, 37, 50],
    [64, 57, 70],
    [93, 80, 84],
    [128, 106, 99],
    [170, 139, 116],
    [213, 185, 146],
    [244, 229, 189],
];

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CartridgePngMetadata {
    pub title: String,
    pub author: String,
    pub year: u16,
    pub players: u8,
    pub controls: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CartridgePng {
    pub cartridge: Vec<u8>,
    pub metadata: CartridgePngMetadata,
}

/// Encodes canonical cartridge bytes into the deterministic PX-240C PNG object.
///
/// # Errors
///
/// Returns an error when the cartridge or identity metadata violates its bounded schema.
pub fn encode_cartridge_png(
    cartridge: &[u8],
    metadata: &CartridgePngMetadata,
) -> Result<Vec<u8>, String> {
    validate(cartridge, metadata)?;
    let mut rgba = vec![0_u8; WIDTH * HEIGHT * 4];
    fill(&mut rgba, 0, 0, WIDTH, HEIGHT, 2);
    fill(&mut rgba, 12, 8, 296, 224, 4);
    fill(&mut rgba, 20, 18, 280, 186, 1);
    fill(&mut rgba, 28, 26, 264, 162, 0);
    fill(&mut rgba, 20, 194, 280, 30, 7);
    let mut header = [0_u8; 13];
    header[..4].copy_from_slice(
        &u32::try_from(WIDTH)
            .map_err(|_| "width overflow")?
            .to_be_bytes(),
    );
    header[4..8].copy_from_slice(
        &u32::try_from(HEIGHT)
            .map_err(|_| "height overflow")?
            .to_be_bytes(),
    );
    header[8..].copy_from_slice(&[8, 6, 0, 0, 0]);
    let metadata = serde_json::to_vec(metadata).map_err(|error| error.to_string())?;
    let mut scanlines = vec![0_u8; HEIGHT * (1 + WIDTH * 4)];
    for row in 0..HEIGHT {
        let source = row * WIDTH * 4;
        let target = row * (1 + WIDTH * 4) + 1;
        scanlines[target..target + WIDTH * 4].copy_from_slice(&rgba[source..source + WIDTH * 4]);
    }
    let mut output = PNG_SIGNATURE.to_vec();
    chunk(&mut output, *b"IHDR", &header)?;
    chunk(&mut output, *b"pxCm", &metadata)?;
    chunk(&mut output, *b"pxCa", cartridge)?;
    chunk(&mut output, *b"IDAT", &zlib_stored(&scanlines)?)?;
    chunk(&mut output, *b"IEND", &[])?;
    Ok(output)
}

/// Extracts one CRC-checked bounded cartridge and its identity metadata from PNG.
///
/// # Errors
///
/// Returns an error for malformed chunks, bad CRCs, duplicates, trailing bytes, or invalid bounds.
pub fn decode_cartridge_png(bytes: &[u8]) -> Result<CartridgePng, String> {
    if bytes.len() < PNG_SIGNATURE.len()
        || bytes.len() > MAX_PNG_BYTES
        || !bytes.starts_with(&PNG_SIGNATURE)
    {
        return Err("invalid cartridge PNG size or signature".to_owned());
    }
    let mut offset = PNG_SIGNATURE.len();
    let mut payload: Option<Vec<u8>> = None;
    let mut metadata: Option<CartridgePngMetadata> = None;
    let mut ended = false;
    while offset < bytes.len() {
        if ended || bytes.len() - offset < 12 {
            return Err("truncated or trailing PNG chunk".to_owned());
        }
        let length = usize::try_from(u32::from_be_bytes(
            bytes[offset..offset + 4]
                .try_into()
                .map_err(|_| "chunk length")?,
        ))
        .map_err(|_| "chunk length overflow")?;
        let end = offset
            .checked_add(12)
            .and_then(|value| value.checked_add(length))
            .ok_or("chunk overflow")?;
        if length > MAX_PNG_BYTES || end > bytes.len() {
            return Err("invalid PNG chunk length".to_owned());
        }
        let kind: [u8; 4] = bytes[offset + 4..offset + 8]
            .try_into()
            .map_err(|_| "chunk type")?;
        let data = &bytes[offset + 8..offset + 8 + length];
        let expected = u32::from_be_bytes(
            bytes[offset + 8 + length..end]
                .try_into()
                .map_err(|_| "chunk CRC")?,
        );
        let mut checked = kind.to_vec();
        checked.extend_from_slice(data);
        if crc32(&checked) != expected {
            return Err("PNG chunk CRC mismatch".to_owned());
        }
        match &kind {
            b"pxCa"
                if payload.is_none()
                    && !data.is_empty()
                    && data.len() <= CARTRIDGE_CAPACITY_BYTES =>
            {
                payload = Some(data.to_vec());
            }
            b"pxCa" => return Err("invalid or duplicate cartridge payload".to_owned()),
            b"pxCm" if metadata.is_none() && data.len() <= 2048 => {
                metadata = Some(
                    serde_json::from_slice(data).map_err(|_| "invalid cartridge PNG metadata")?,
                );
            }
            b"pxCm" => return Err("invalid or duplicate cartridge metadata".to_owned()),
            b"IEND" if data.is_empty() => ended = true,
            _ => {}
        }
        offset = end;
    }
    if !ended {
        return Err("cartridge PNG has no IEND".to_owned());
    }
    let cartridge = payload.ok_or("cartridge PNG has no payload")?;
    let metadata = metadata.ok_or("cartridge PNG has no metadata")?;
    validate(&cartridge, &metadata)?;
    Ok(CartridgePng {
        cartridge,
        metadata,
    })
}

fn validate(cartridge: &[u8], metadata: &CartridgePngMetadata) -> Result<(), String> {
    if cartridge.is_empty() || cartridge.len() > CARTRIDGE_CAPACITY_BYTES {
        return Err("cartridge payload exceeds capacity".to_owned());
    }
    if metadata.title.is_empty()
        || metadata.title.len() > 64
        || metadata.author.is_empty()
        || metadata.author.len() > 64
        || !(1970..=9999).contains(&metadata.year)
        || !(1..=4).contains(&metadata.players)
        || metadata.controls.len() > 64
    {
        return Err("invalid cartridge PNG metadata".to_owned());
    }
    Ok(())
}

fn fill(rgba: &mut [u8], left: usize, top: usize, width: usize, height: usize, color: usize) {
    for y in top..top + height {
        for x in left..left + width {
            let offset = (y * WIDTH + x) * 4;
            rgba[offset..offset + 3].copy_from_slice(&PALETTE[color]);
            rgba[offset + 3] = 255;
        }
    }
}

fn chunk(output: &mut Vec<u8>, kind: [u8; 4], data: &[u8]) -> Result<(), String> {
    output.extend_from_slice(
        &u32::try_from(data.len())
            .map_err(|_| "PNG chunk too large")?
            .to_be_bytes(),
    );
    output.extend_from_slice(&kind);
    output.extend_from_slice(data);
    let mut checked = kind.to_vec();
    checked.extend_from_slice(data);
    output.extend_from_slice(&crc32(&checked).to_be_bytes());
    Ok(())
}

fn zlib_stored(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let blocks = bytes.len().div_ceil(u16::MAX.into()).max(1);
    let mut output = Vec::with_capacity(2 + bytes.len() + blocks * 5 + 4);
    output.extend_from_slice(&[0x78, 0x01]);
    for (index, block) in bytes.chunks(usize::from(u16::MAX)).enumerate() {
        output.push(u8::from(index + 1 == blocks));
        let length = u16::try_from(block.len()).map_err(|_| "DEFLATE block too large")?;
        output.extend_from_slice(&length.to_le_bytes());
        output.extend_from_slice(&(!length).to_le_bytes());
        output.extend_from_slice(block);
    }
    output.extend_from_slice(&adler32(bytes).to_be_bytes());
    Ok(output)
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = u32::MAX;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ if crc & 1 == 1 { 0xedb8_8320 } else { 0 };
        }
    }
    crc ^ u32::MAX
}

fn adler32(bytes: &[u8]) -> u32 {
    let (mut first, mut second) = (1_u32, 0_u32);
    for byte in bytes {
        first = (first + u32::from(*byte)) % 65_521;
        second = (second + first) % 65_521;
    }
    (second << 16) | first
}

#[cfg(test)]
mod tests {
    use super::{CartridgePngMetadata, decode_cartridge_png, encode_cartridge_png};

    #[test]
    fn cartridge_png_round_trips_and_checks_corruption() {
        let metadata = CartridgePngMetadata {
            title: "TEST".to_owned(),
            author: "@gongahkia".to_owned(),
            year: 1999,
            players: 2,
            controls: "PAD".to_owned(),
        };
        let png = encode_cartridge_png(b"PXC1test", &metadata).expect("encode");
        let decoded = decode_cartridge_png(&png).expect("decode");
        assert_eq!(decoded.cartridge, b"PXC1test");
        assert_eq!(decoded.metadata, metadata);
        let mut corrupt = png;
        corrupt[20] ^= 1;
        assert!(decode_cartridge_png(&corrupt).unwrap_err().contains("CRC"));
    }
}
