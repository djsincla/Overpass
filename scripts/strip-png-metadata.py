"""Drops a PNG's EXIF and XMP chunks, so no viewer turns it by a leftover orientation tag."""
import struct, sys

for path in sys.argv[1:]:
    data = open(path, "rb").read()
    out, i = bytearray(data[:8]), 8
    while i < len(data):
        length = struct.unpack(">I", data[i:i + 4])[0]
        if data[i + 4:i + 8] not in (b"eXIf", b"iTXt"):
            out += data[i:i + 12 + length]
        i += 12 + length
    open(path, "wb").write(out)
