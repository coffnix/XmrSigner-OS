#!/usr/bin/env python3
import sys, os, argparse, mmap, numpy as np

def read_sysfs(path, default=None, conv=int):
    try:
        with open(path, 'r') as f:
            s = f.read().strip()
        return conv(s)
    except Exception:
        return default

def get_fb_geom(dev="/dev/fb0"):
    base = f"/sys/class/graphics/{os.path.basename(dev)}"
    xres_yres = read_sysfs(f"{base}/virtual_size", None, lambda s: tuple(map(int, s.split(','))))
    bpp = read_sysfs(f"{base}/bits_per_pixel", 32, int)
    stride = read_sysfs(f"{base}/stride", None, int)
    if xres_yres is None:
        xres_yres = (640, 480)
    xres, yres = xres_yres
    bytespp = (bpp + 7) // 8
    line_len = stride if stride else xres * bytespp
    smem_len = line_len * yres
    return xres, yres, bpp, line_len, smem_len

def yuv420_to_bgra(yuv, w, h):
    y_size = w * h
    uv_w, uv_h = w // 2, h // 2
    uv_size = uv_w * uv_h

    y = np.frombuffer(yuv, dtype=np.uint8, count=y_size, offset=0).reshape(h, w)
    u = np.frombuffer(yuv, dtype=np.uint8, count=uv_size, offset=y_size).reshape(uv_h, uv_w)
    v = np.frombuffer(yuv, dtype=np.uint8, count=uv_size, offset=y_size + uv_size).reshape(uv_h, uv_w)

    u2 = u.repeat(2, axis=0).repeat(2, axis=1).astype(np.float32) - 128.0
    v2 = v.repeat(2, axis=0).repeat(2, axis=1).astype(np.float32) - 128.0
    y_f = y.astype(np.float32)

    r = np.clip(y_f + 1.402 * v2, 0, 255).astype(np.uint8)
    g = np.clip(y_f - 0.344136 * u2 - 0.714136 * v2, 0, 255).astype(np.uint8)
    b = np.clip(y_f + 1.772 * u2, 0, 255).astype(np.uint8)

    a = np.zeros_like(r, dtype=np.uint8)
    bgra = np.dstack([b, g, r, a]).astype(np.uint8)
    return bgra.tobytes()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fb", default="/dev/fb0")
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--input", choices=["yuv420", "bgra"], default="yuv420")
    args = ap.parse_args()

    in_w, in_h = args.width, args.height
    if args.input == "bgra":
        frame_size = in_w * in_h * 4
    else:
        frame_size = in_w * in_h + 2 * ((in_w // 2) * (in_h // 2))

    fb = os.open(args.fb, os.O_RDWR)
    try:
        xres, yres, bpp, line_len, smem_len = get_fb_geom(args.fb)
        bytespp = (bpp + 7) // 8

        fbmap = mmap.mmap(fb, smem_len, mmap.MAP_SHARED, mmap.PROT_WRITE | mmap.PROT_READ, 0)
        try:
            copy_w = min(in_w, xres)
            copy_h = min(in_h, yres)

            if args.input == "bgra":
                row_bytes_in = in_w * 4
                row_bytes_copy = min(copy_w * 4, line_len)
            else:
                row_bytes_in = in_w * bytespp  # after convert -> assume 32bpp on fb
                row_bytes_copy = min(copy_w * bytespp, line_len)

            read = sys.stdin.buffer.read
            while True:
                buf = read(frame_size)
                if not buf or len(buf) < frame_size:
                    break

                if args.input == "bgra":
                    frame_bytes = buf
                else:
                    if bpp != 32:
                        # only 32bpp is supported in this fast path
                        continue
                    frame_bytes = yuv420_to_bgra(buf, in_w, in_h)

                for y in range(copy_h):
                    src_off = y * row_bytes_in
                    dst_off = y * line_len
                    fbmap[dst_off:dst_off+row_bytes_copy] = frame_bytes[src_off:src_off+row_bytes_copy]
        finally:
            fbmap.close()
    finally:
        os.close( fb )

if __name__ == "__main__":
    main()
