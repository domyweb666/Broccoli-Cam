"""聆聽者短片的轉檔與檢查。

用法：
    python -I tools/companion_clips.py <原始影片資料夾> <定格圖.png> <輸出資料夾> [--fix-seam] [--person a] [--crf 22]

對資料夾裡每一支 companion_*.mp4：
  1. 裁成 9:16、縮到 720×1280、30 fps、刪音軌，輸出 H.264 MP4
  2. 比對第一幀、最後一幀和定格圖的 SSIM（接縫檢查）
  3. 抽 8 格排成一條，存成 <名稱>_frames.png 方便人眼看動作
--fix-seam：最後 0.2 秒淡回定格圖，讓尾幀和定格圖一致。
--person b：只處理 companion_b_*.mp4。三位聆聽者的定格圖不同，同一個資料夾要分三次跑。
--crf 24：壓縮率，預設 22，數字越大檔案越小。
「臉首vs尾」只比臉那一塊，毛衣紋理壓縮後每一格都有雜訊，整張的數字會被拉低，接縫看這一欄，0.96 以上算過。
動作起點太晚的片先用 tools/companion_trim.py 剪過，再拿剪好的當原始檔。
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

W, H = 720, 1280
FPS = 30
SEAM_FADE = 0.2
# 臉部區域（720×1280 裡的 寬:高:x:y），三位聆聽者構圖一樣，共用一組。
FACE = "420:500:150:20"
VF_SQUARE = f"crop='min(iw,ih*9/16)':'min(ih,iw*16/9)',scale={W}:{H},fps={FPS},format=yuv420p"


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        raise SystemExit(f"[companion_clips] 指令失敗：{' '.join(map(str, cmd))}\n{r.stderr[-2000:]}")
    return r


def duration(path):
    r = run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)])
    return float(r.stdout.strip())


def ssim(a, b, crop=None):
    cut = f",crop={crop}" if crop else ""
    r = run(["ffmpeg", "-hide_banner", "-i", str(a), "-i", str(b), "-lavfi",
             f"[0]scale={W}:{H},format=gray{cut}[x];[1]scale={W}:{H},format=gray{cut}[y];[x][y]ssim",
             "-f", "null", "-"])
    m = re.search(r"All:([0-9.]+)", r.stderr)
    return float(m.group(1)) if m else float("nan")


def convert(src, dst, hub, fix_seam, crf):
    if not fix_seam:
        run(["ffmpeg", "-y", "-hide_banner", "-i", str(src), "-an", "-vf", VF_SQUARE,
             "-c:v", "libx264", "-crf", crf, "-preset", "slow", "-pix_fmt", "yuv420p",
             "-movflags", "+faststart", str(dst)])
        return
    length = duration(src)
    # 多留兩幀，讓最後一幀完全是定格圖（最後一幀的時間點比片長早 1/FPS）。
    offset = max(0.0, length - SEAM_FADE - 2.0 / FPS)
    run(["ffmpeg", "-y", "-hide_banner", "-i", str(src), "-loop", "1", "-t", str(SEAM_FADE + 0.1), "-i", str(hub),
         "-filter_complex",
         f"[0]{VF_SQUARE},settb=AVTB[a];[1]{VF_SQUARE},settb=AVTB[b];"
         f"[a][b]xfade=transition=fade:duration={SEAM_FADE}:offset={offset:.3f}[v]",
         "-map", "[v]", "-an", "-t", f"{length:.3f}", "-c:v", "libx264", "-crf", crf, "-preset", "slow",
         "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(dst)])


def frames_strip(clip, out_png, count=8):
    length = duration(clip)
    fps = count / length
    run(["ffmpeg", "-y", "-hide_banner", "-i", str(clip), "-vf",
         f"fps={fps:.4f},scale=180:320,tile={count}x1", "-frames:v", "1", str(out_png)])


def main():
    args = sys.argv[1:]

    def option(name, default):
        if name not in args:
            return default
        i = args.index(name)
        value = args[i + 1]
        del args[i:i + 2]
        return value

    person, crf = option("--person", None), option("--crf", "22")
    fix_seam = "--fix-seam" in args
    args = [a for a in args if not a.startswith("--")]
    if len(args) != 3:
        raise SystemExit(__doc__)
    src_dir, hub, out_dir = Path(args[0]), Path(args[1]), Path(args[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    pattern = f"companion_{person}_*.mp4" if person else "companion_*.mp4"
    clips = sorted(src_dir.glob(pattern))
    if not clips:
        raise SystemExit(f"[companion_clips] {src_dir} 裡沒有 {pattern}")

    print(f"{'檔名':<22}{'秒數':>6}{'大小KB':>8}{'首幀vs定格':>11}{'尾幀vs定格':>11}{'首vs尾':>8}{'臉首vs尾':>9}")
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for src in clips:
            dst = out_dir / src.name
            convert(src, dst, hub, fix_seam, crf)
            first, last = tmp / "first.png", tmp / "last.png"
            run(["ffmpeg", "-y", "-hide_banner", "-i", str(dst), "-frames:v", "1", str(first)])
            run(["ffmpeg", "-y", "-hide_banner", "-sseof", "-0.1", "-i", str(dst), "-update", "1", str(last)])
            frames_strip(dst, out_dir / f"{dst.stem}_frames.png")
            print(f"{dst.name:<22}{duration(dst):>6.2f}{dst.stat().st_size // 1024:>8}"
                  f"{ssim(first, hub):>11.3f}{ssim(last, hub):>11.3f}{ssim(first, last):>8.3f}"
                  f"{ssim(first, last, FACE):>9.3f}")


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    main()
