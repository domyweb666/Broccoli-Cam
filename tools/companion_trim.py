"""量點頭片、反應片的動作起點，起點太晚就縮短前面的靜止段。

用法：
    python -I tools/companion_trim.py <原始影片資料夾> <輸出資料夾>
    python -I tools/companion_trim.py <原始影片資料夾> --measure

只處理檔名有 nod／brow／tilt／lean 的 companion_*.mp4，待機片不碰。
輸出給 tools/companion_clips.py 當原始檔用（那支負責縮放、壓縮、檢查接縫）。

起點怎麼量：每一格和第一格算光流（逐像素的位移），只看這種動作最主要的方向。
  nod   臉的上下位移。模型幾乎都會先微微抬頭再點下去，起點算「開始往下」那一格。
  brow  眉毛相對於臉的位移，只算往上。
  tilt  臉的旋轉角度。
  lean  臉的放大比例。
後三種的起點是位移第一次到最大幅度 12% 的那一格。

怎麼縮短：起點前面的格抽掉多餘的，brow／tilt／lean 留 0.15 秒，
nod 留 0.27 秒（裡面有抬頭的預備動作，再短會像抽動）。
留下的格照臉的移動量平均取，速度才不會忽快忽慢；
第一格一定留著，第一格是定格圖，接縫不會因為剪裁變差。
起點本來就夠早的片不剪，只重新封裝成 30 fps。
"""
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np

FPS = 30
W, H = 360, 640
ONSET_RATIO = 0.12
KINDS = ("nod", "brow", "tilt", "lean")
LEAD_FRAMES = {"nod": 8, "brow": 5, "tilt": 5, "lean": 5}
# 起點比要留的長度晚這麼多格以上才剪，差一兩格沒必要重壓。
SLACK = 3


def load_gray(path):
    r = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-vf",
                        f"fps={FPS},scale={W}:{H},format=gray", "-f", "rawvideo", "-"], capture_output=True)
    if r.returncode != 0:
        raise SystemExit(f"[companion_trim] 讀不到 {path}：{r.stderr.decode('utf-8', 'replace')[-500:]}")
    return np.frombuffer(r.stdout, np.uint8).reshape(-1, H, W)


def motion(frames):
    """五條曲線：臉上下位移、眉毛往上、旋轉、放大，再加臉的左右位移（位移單位是 360 寬的像素）。"""
    base = cv2.GaussianBlur(frames[0], (0, 0), 1.5)
    rows = []
    for f in frames:
        fl = cv2.calcOpticalFlowFarneback(base, cv2.GaussianBlur(f, (0, 0), 1.5), None, 0.5, 4, 25, 3, 7, 1.5, 0)
        nod = np.median(fl[115:225, 110:250, 1])
        brow = np.median(fl[170:215, 130:230, 1]) - np.median(fl[100:130, 110:250, 1])
        left, right = fl[125:205, 112:150], fl[125:205, 210:248]
        tilt = abs(np.degrees((np.median(right[..., 1]) - np.median(left[..., 1])) / 98))
        lean = (np.median(right[..., 0]) - np.median(left[..., 0])) / 98 * 100
        rows.append((nod, max(brow, 0), tilt, max(lean, 0), np.median(fl[115:225, 110:250, 0])))
    return dict(zip(KINDS + ("dx",), np.array(rows).T))


def onset_frame(curve, kind):
    peak = curve.max()
    if kind != "nod":
        return int(np.argmax(curve >= ONSET_RATIO * peak)), float(peak)
    first_down = int(np.argmax(curve >= 0.5 * peak))
    before = curve[:first_down]
    low = before.min()
    return int(np.flatnonzero(before <= low + 0.15 * (curve[first_down] - low)).max()), float(peak)


def kind_of(path):
    return next((k for k in KINDS if f"_{k}" in path.stem), None)


def kept_indices(total, onset, lead, curves):
    step = np.abs(np.diff(curves["nod"], prepend=0)) + np.abs(np.diff(curves["dx"], prepend=0)) + 0.05
    travelled = np.cumsum(step[:onset + 1])
    targets = np.linspace(travelled[0], travelled[-1], lead, endpoint=False)
    head = {int(np.argmin(np.abs(travelled[:onset] - t))) for t in targets} | {0}
    return sorted(head) + list(range(onset, total))


def main():
    args = sys.argv[1:]
    measure = "--measure" in args
    args = [a for a in args if not a.startswith("--")]
    if len(args) != (1 if measure else 2):
        raise SystemExit(__doc__)
    src_dir = Path(args[0])
    out_dir = None if measure else Path(args[1])
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)

    print(f"{'檔名':<24}{'起點秒':>8}{'最大幅度':>9}{'剪後起點':>9}{'剪後秒數':>9}")
    for src in sorted(src_dir.glob("companion_*.mp4")):
        kind = kind_of(src)
        if kind is None:
            continue
        frames = load_gray(src)
        curves = motion(frames)
        onset, peak = onset_frame(curves[kind], kind)
        late = onset > LEAD_FRAMES[kind] + SLACK
        keep = kept_indices(len(frames), onset, LEAD_FRAMES[kind], curves) if late else list(range(len(frames)))
        new_onset = keep.index(onset) / FPS
        if out_dir:
            dst = out_dir / src.name
            expr = "+".join(f"eq(n\\,{i})" for i in keep if i < onset) or "0"
            vf = f"fps={FPS},select='{expr}+gte(n\\,{onset})',setpts=N/{FPS}/TB" if late else f"fps={FPS}"
            # 中間檔壓得很輕，真正的壓縮留給 companion_clips.py。
            r = subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(src), "-an", "-vf", vf,
                                "-c:v", "libx264", "-crf", "8", "-preset", "medium", "-pix_fmt", "yuv420p", str(dst)],
                               capture_output=True, text=True, encoding="utf-8", errors="replace")
            if r.returncode != 0:
                raise SystemExit(f"[companion_trim] 剪不了 {src}：{r.stderr[-500:]}")
        print(f"{src.name:<24}{onset / FPS:>8.2f}{peak:>9.1f}{new_onset:>9.2f}{len(keep) / FPS:>9.2f}")


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    main()
