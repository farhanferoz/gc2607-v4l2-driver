"""Read-only: did the last hibernate image finish writing, and which kernel wrote it?

Run as root after a hibernate that never came back, BEFORE the swapfile is used again:
    sudo python3 gc2607-hib-image-probe.py
Complete chain + a kernel release only that kernel could hold => the WRITE finished and the RESUME hung
(2026-09-22: 2776 map pages, 91,123 chunks framed OK, 7.2.5 text in 82 chunks). A broken chain or an
older release => the write never finished. The swap signature is reset by any resume attempt that finds
the image (swsusp_check), but header.image is left in place, which is what makes this readable later.

Formats from linux v7.2 kernel/power/swap.c: swap_map_page = 511 u64 entries + u64 next_swap;
entries[0] is the info page; every later entry is image data written as compressed chunks,
each starting with a u64 cmp_len (CMP_HEADER) and padded to whole pages.
On x86 the info page (entries[0]) holds restore_data_record over the uts, so the kernel
release is read from the compressed data instead.
"""

import struct

DEV = "/dev/nvme0n1p8"
RESUME_PAGE = 22100502  # resume_offset= on the kernel command line
PAGE = 4096
ENTRIES = 511
CMP_SIZE_MAX = 40 * PAGE  # generous upper bound on one compressed 32-page chunk
TAGS = (b"7.2.5-200", b"7.2.4-200", b"7.1.13-200")
SCAN_PAGES = 30000
MAX_MAP_PAGES = 20000  # a 36 GB swap file holds at most ~17,500 map pages


def page(f, n: int) -> bytes:
    """Return one 4 KiB page at page offset n."""
    f.seek(n * PAGE)
    return f.read(PAGE)


def main() -> None:
    """Walk map pages, validate chunk framing, and locate kernel release strings."""
    with open(DEV, "rb") as f:
        hdr = page(f, RESUME_PAGE)
        (image,) = struct.unpack_from("<Q", hdr, 4064)
        (flags,) = struct.unpack_from("<I", hdr, 4072)
        print(f"swap header: sig={hdr[4086:4096]!r} flags={flags:#x} image_page={image}")
        if not image:
            print("header.image is 0: no hibernate image has ever been completed on this swap")
            return
        entries: list[int] = []
        map_pages, nxt, bad_map = 0, image, None
        while nxt:
            mp = page(f, nxt)
            map_pages += 1
            vals = struct.unpack_from("<512Q", mp)
            entries.extend(v for v in vals[:ENTRIES] if v)
            nxt = vals[ENTRIES]
            if map_pages > MAX_MAP_PAGES:
                bad_map = f"map chain longer than {MAX_MAP_PAGES} pages - not a valid chain"
                break
        print(f"map_pages={map_pages} data_entries={len(entries)} chain_end={'next_swap=0 (terminated)' if not bad_map else bad_map}")

        i, chunks, cmp_total, framing_err = 1, 0, 0, None
        tag_hits: dict[bytes, list[int]] = {t: [] for t in TAGS}
        while i < len(entries):
            head = page(f, entries[i])
            (cmp_len,) = struct.unpack_from("<Q", head, 0)
            if not 0 < cmp_len <= CMP_SIZE_MAX:
                framing_err = f"bad cmp_len={cmp_len} at chain index {i} (page {entries[i]})"
                break
            n = (8 + cmp_len + PAGE - 1) // PAGE
            if i < SCAN_PAGES:
                body = head + b"".join(page(f, entries[j]) for j in range(i + 1, min(i + n, len(entries))))
                for t in TAGS:
                    if t in body:
                        tag_hits[t].append(i)
            chunks += 1
            cmp_total += cmp_len
            i += n
        print(
            f"chunks={chunks} compressed_bytes={cmp_total} framing={'OK to the last entry' if not framing_err and i == len(entries) else framing_err or f'overran: i={i} entries={len(entries)}'}"
        )
        for t, hits in tag_hits.items():
            print(f"{t.decode()}: {len(hits)} chunks contain it (first chain indices {hits[:5]}) within first {SCAN_PAGES} chain pages")


if __name__ == "__main__":
    main()
