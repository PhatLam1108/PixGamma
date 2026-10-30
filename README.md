<p align="center">
  <img src="docs/brand/logo.svg" width="96" alt="Logo PixGamma">
</p>

<h1 align="center">PixGamma</h1>

<p align="center">
  Phóng to và phục hồi ảnh bằng AI trên Mac. Chạy hoàn toàn trên máy bằng GPU Apple Silicon.<br>
  Làm cho người chụp và viết review laptop: giữ đúng chữ trên phím, kết cấu thật, màu thật.
</p>

<p align="center">
  <img alt="Phiên bản" src="https://img.shields.io/badge/phi%C3%AAn%20b%E1%BA%A3n-0.2.1-1647C6">
  <img alt="Nền tảng" src="https://img.shields.io/badge/n%E1%BB%81n%20t%E1%BA%A3ng-macOS%2014%2B%20%C2%B7%20Apple%20Silicon-0B2A6F">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6-F05138">
  <img alt="Giao diện" src="https://img.shields.io/badge/UI-SwiftUI%20%2B%20Core%20ML-1647C6">
  <img alt="Giấy phép" src="https://img.shields.io/badge/d%C3%B9ng-mi%E1%BB%85n%20ph%C3%AD%2C%20phi%20th%C6%B0%C6%A1ng%20m%E1%BA%A1i-2E7D5B">
</p>

<p align="center">
  <b>Tiếng Việt</b> · <a href="README.en.md">English</a> · <a href="CHANGELOG.md">Nhật ký thay đổi</a> · <a href="../../releases/latest">Tải bản mới nhất</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/hero-vi-dark.webp">
    <img src="docs/brand/hero-vi-light.webp" width="100%" alt="PixGamma: con vẹt và chân dung trước/sau khi phóng 4x">
  </picture>
</p>

---

## Giới thiệu

PixGamma nhận một ảnh nhỏ, mờ hoặc đã nén và trả lại bản lớn hơn 2x đến 16x, có lại chi tiết. Gồm app macOS, lệnh `pixgamma` để xử lý hàng loạt và HTTP API cục bộ để nối vào quy trình đăng bài.

PixGamma là tên mới của **Pixora** (đến bản 0.2.1): bản cũ tự cập nhật lên PixGamma, lệnh `pixora` và các biến `PIXORA_*` vẫn dùng được.

Ba nguyên tắc thiết kế:

- **Ảnh không rời khỏi máy.** Mọi xử lý chạy bằng Core ML trên GPU Apple Silicon. Không tài khoản, không máy chủ, không gửi ảnh đi đâu.
- **Không bịa chữ.** Chữ trên phím laptop, nhãn, banner được nhận diện riêng (có tiếng Việt) và dựng lại bằng model chữ riêng. Chữ quá nhỏ để dựng lại đúng thì được giữ trung thực, không vẽ thành chữ khác.
- **Giữ ảnh là ảnh của bạn.** Màu, tông và nét mặt gốc được giữ lại; chi tiết sinh thêm luôn có thanh chỉnh độ mạnh.

## Cài đặt

1. Vào trang [Releases](../../releases/latest) và tải `PixGamma-<phiên bản>.dmg`.
2. Mở file DMG, kéo **PixGamma** vào **Applications**.
3. Lần đầu mở: chuột phải vào PixGamma trong Applications → **Open** → **Open**.
   App được ký ad-hoc, chưa qua notarize của Apple, nên macOS hỏi xác nhận một lần.
4. Muốn dùng lệnh `pixgamma` trong Terminal: trong DMG, bấm đúp **Cài lệnh pixgamma (CLI).command**.

Nếu macOS báo ứng dụng "bị hỏng" hoặc không cho mở, chạy lệnh sau một lần:

```bash
xattr -dr com.apple.quarantine /Applications/PixGamma.app
```

### Tự cập nhật

PixGamma tự kiểm tra bản mới mỗi ngày một lần; kiểm tra ngay ở menu **PixGamma → Kiểm tra cập nhật…** Khi có bản mới, app hiện ghi chú phát hành, tải file DMG, kiểm tra mã SHA-256, thay app rồi tự mở lại.

Repo PixGamma công khai nên **không cần token GitHub**. Không có token, GitHub cho mỗi địa chỉ IP 60 lần gọi mỗi giờ, thừa cho việc kiểm tra cập nhật. Nếu app báo hết lượt (vd nhiều máy chung một mạng), có thể dùng thêm một token để có 5.000 lượt mỗi giờ:

1. Mở [trang tạo token](https://github.com/settings/personal-access-tokens/new) (Fine-grained token).
2. **Repository access**: Public repositories (read-only); không cần thêm quyền nào.
3. Trong hộp thoại cập nhật báo lỗi, bấm **Dùng token GitHub…** rồi dán token. Token được cất trong Keychain của máy.

Từ Terminal: `pixgamma update` (kiểm tra), `pixgamma update --install` (cài, cần đóng app trước), `pixgamma update --token <token>` (lưu token, không bắt buộc). Biến `PIXGAMMA_GITHUB_TOKEN` dùng thay Keychain cho script.

### Chế độ Recover (tùy chọn)

Recover dùng diffusion để vẽ lại da, lỗ chân lông, sợi tóc, lông thú. Bộ model nặng khoảng 2,7 GB nên tách khỏi DMG:

1. Tải `PixGamma-Recover-<phiên bản>-1.zip` và `-2.zip` ở trang Releases vào thư mục **Downloads**.
2. Trong DMG, bấm đúp **Cài model Recover.command**. Model được cài vào `~/Library/Application Support/PixGamma/Models/Recover`.
3. Mở lại PixGamma, thẻ **Recover** sẽ hiện ra.

### Yêu cầu

| | Tối thiểu | Khuyến nghị |
|---|---|---|
| macOS | 14 Sonoma | 15 trở lên |
| Chip | Apple Silicon M1 | M2/M3/M4 Pro, Max hoặc Ultra |
| RAM | 8 GB (các chế độ phóng thường) | 32 GB trở lên cho Recover |
| Ổ trống | 1 GB | 4 GB nếu cài Recover |

### Gỡ cài đặt

Xóa `/Applications/PixGamma.app` và thư mục `~/Library/Application Support/PixGamma`. Nếu đã cài CLI, xóa thêm file `pixgamma` trong `/opt/homebrew/bin`, `/usr/local/bin` hoặc `~/.local/bin`.

## Ví dụ

Ảnh gốc được thu nhỏ 4 lần (400 đến 480 px) rồi phóng lại 4x. Mỗi ảnh đặt PixGamma Photo v7 cạnh Photo v6, UltraSharpV2 và ảnh gốc; khung vàng là vùng được cắt phóng to bên dưới, số DISTS lấy từ bộ chấm chi tiết mịn (thấp hơn là giống ảnh gốc hơn).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/samples/compare-macaw-v7-vi-dark.webp">
  <img src="docs/samples/compare-macaw-v7-vi-light.webp" width="100%" alt="Lông vẹt: Photo v6, Photo v7, UltraSharpV2 và ảnh gốc">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/samples/compare-hair-v7-vi-dark.webp">
  <img src="docs/samples/compare-hair-v7-vi-light.webp" width="100%" alt="Tóc: Photo v6, Photo v7, UltraSharpV2 và ảnh gốc">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/samples/compare-skin-v7-vi-dark.webp">
  <img src="docs/samples/compare-skin-v7-vi-light.webp" width="100%" alt="Lông mày và da: Photo v6, Photo v7, UltraSharpV2 và ảnh gốc">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/samples/compare-fur-v7-vi-dark.webp">
  <img src="docs/samples/compare-fur-v7-vi-light.webp" width="100%" alt="Lông mèo: ảnh vào, UltraSharpV2, Photo v7 và ảnh gốc">
</picture>

| Biển chào ở Fenit, Ireland (giữ chữ; bicubic, PixGamma 4x qua app, ảnh gốc) |
|---|
| ![Biển chữ: bicubic, PixGamma và ảnh gốc](docs/samples/compare-sign-vi.jpg) |

Nguồn ảnh mẫu ở [docs/samples/CREDITS.md](docs/samples/CREDITS.md) (CC0 và public domain).

## Tính năng

| Mảng | Nội dung |
|---|---|
| **Chế độ AI** | **Auto** (tự đo nhiễu, độ nét, khối JPEG, khuôn mặt rồi chọn model); **Standard** (PixGamma Photo v7, DAT2 fine-tune riêng từ UltraSharpV2, train thêm trên ảnh cận lông chim, tóc, da để sợi tóc, lông mày, lỗ chân lông rõ hơn mà vẫn giống ảnh gốc; vùng chữ dùng PixGamma Text v3, Photo v1 train thêm trên chữ tiếng Việt có dấu, và SPAN huấn luyện trên ảnh chụp thật bị nén, mờ, nhiễu; giữ đúng chất liệu, không vẽ vân giả); **High Fidelity** (trung thực, thanh Detail); **Art & CGI**; **Low Resolution** (khử nhiễu liên tục); **Recover** (tái tạo điểm ảnh bằng diffusion; tự nhận diện nội dung ảnh để viết mô tả, ví dụ "vẹt, lông chi tiết"; tự chọn độ bám ảnh gốc 85 cho động vật, tóc, da; có chốt an toàn cho ảnh có chữ, bản đồ, sản phẩm để không vẽ lại hình khối). |
| **Chữ** | Apple Vision dò và đọc chữ, có tiếng Việt đủ dấu. Vùng chữ dựng lại bằng **model chữ riêng** (RealPLKSR fine-tune trên chữ Việt/Anh tự sinh), lấy trung bình 8 lượt lật/xoay cho nét thẳng. Đo cỡ từng dòng từ điểm ảnh: dòng quá nhỏ (chữ hoa dưới ~4 px) giữ bản trung thực. |
| **Khuôn mặt** | Chân thực (CodeFormer, có thanh giữ nét mặt gốc) hoặc Sáng tạo (GFPGAN). Recover có thêm lượt riêng cho mắt và lông mày. |
| **Kích thước** | Theo tỉ lệ 1–16x, theo chiều rộng hoặc chiều cao. Chọn mức gốc 2x/4x đủ dùng, chồng lượt khi trên 4x. Chia ô có ngữ cảnh nên không lộ đường ghép. |
| **Tinh chỉnh** | Khử nhiễu, làm nét, khử nén JPEG, khử viền sáng, tương phản cục bộ và độ rực, kết cấu hạt. Giữ màu gốc sau khi phóng. Ảnh nền trong suốt giữ được alpha. |
| **Xuất file** | PNG, JPEG, TIFF, HEIC hoặc giữ định dạng gốc. Giữ EXIF/GPS/IPTC, ghi DPI, đặt tiền tố/hậu tố, không bao giờ ghi đè ảnh gốc. |
| **CLI và API** | `pixgamma` xử lý hàng loạt, đệ quy thư mục, in JSON. `pixgamma serve` mở HTTP API cục bộ, bật được ngay trong app. |
| **Tốc độ** | Mặc định chạy GPU. Trên Mac Studio M2 Ultra: ảnh 800×600 lên 4x khoảng 5–8 giây (Standard), lên 2x khoảng 1 giây; Recover ảnh 1536 px khoảng 35 giây. |

## Dùng CLI

```bash
pixgamma upscale anh.jpg --scale 4
```

```bash
pixgamma upscale ~/Anh/laptop -r -o ~/Anh/out -m std --scale 2 -f jpg --jq 92 --se
```

```bash
pixgamma upscale chan-dung.jpg -m rec --cr 75
```

| Cờ | Ý nghĩa |
|---|---|
| `-m` | `auto`, `std`, `hf`, `art`, `low`, `rec` |
| `--scale`, `--width`, `--height` | Kích thước đầu ra |
| `--dn`, `--sh`, `--cm`, `--dh` | Khử nhiễu, làm nét, khử nén JPEG, khử viền sáng (0–100) |
| `--dt`, `--tx`, `--lc` | Detail (High Fidelity), kết cấu hạt, tương phản cục bộ |
| `--fr`, `--frc`, `--frf` | Phục hồi khuôn mặt, kiểu `realistic`/`creative`, mức giữ mặt gốc |
| `--cr`, `--rs`, `--prompt` | Recover: Creativity, Resemblance (mặc định theo loại ảnh), prompt tùy chọn (mặc định tự mô tả) |
| `--no-text-protect`, `--no-color-fix` | Tắt giữ chữ, tắt giữ màu gốc |
| `-f`, `--jq`, `--res` | Định dạng, chất lượng JPEG/HEIC, DPI |
| `-r`, `-o`, `--se`, `--am` | Đệ quy, thư mục ra, bỏ qua file đã có, thêm tên model vào tên file |
| `-d` | `gpu` (mặc định), `all`, `ane`, `cpu` |
| `--json`, `-q` | In báo cáo JSON (có chữ đọc được), chạy im lặng |

Xem đủ bằng `pixgamma upscale --help`. Lệnh khác: `pixgamma analyze anh.jpg` (in thiết lập Auto đề xuất), `pixgamma models` (liệt kê model và vị trí file).

## Dùng API

```bash
pixgamma serve --port 8765
```

```bash
curl --data-binary @anh.jpg "http://127.0.0.1:8765/v1/upscale?mode=std&scale=2&format=jpg" -o anh-2x.jpg
```

Điểm cuối: `/health`, `/v1/models`, `/v1/analyze`, `/v1/upscale`. Tham số của `/v1/upscale`: `mode`, `scale` hoặc `width`/`height`, `denoise`, `sharpen`, `compression`, `detail`, `texture`, `contrast`, `dehalo`, `face`, `face_style=realistic|creative`, `face_fidelity`, `creativity`, `resemblance`, `prompt`, `text=0|1`, `color=0|1`, `device=gpu|all|ane|cpu`, `format=png|jpg|tiff|heic`, `quality`. Báo cáo nằm trong header `X-PixGamma-Report`; gửi `Accept: application/json` để nhận JSON kèm ảnh base64.

## Xử lý sự cố

| Hiện tượng | Cách xử lý |
|---|---|
| macOS không cho mở, báo "bị hỏng" | Chạy `xattr -dr com.apple.quarantine /Applications/PixGamma.app` rồi mở lại |
| `pixgamma: command not found` | Bấm đúp **Cài lệnh pixgamma (CLI).command** trong DMG, mở Terminal mới |
| Không thấy thẻ Recover | Chưa cài model Recover, xem mục Chế độ Recover |
| Cập nhật báo "GitHub giới hạn 60 lần kiểm tra mỗi giờ" | Chờ tới giờ được báo, hoặc bấm **Dùng token GitHub…** và dán một token (xem [Tự cập nhật](#tự-cập-nhật)) |
| Cập nhật báo "Token GitHub đã lưu không hợp lệ" | Bấm **Xoá token** trong hộp thoại cập nhật (repo công khai không cần token), hoặc `PIXGAMMA_GITHUB_TOKEN` đang đặt sai: bỏ biến này |
| Lần chạy đầu chậm hơn hẳn | Core ML compile model cho máy ở lần đầu (vài chục giây), các lần sau nhanh |
| Máy chậm khi chạy Recover | Recover dùng nhiều RAM GPU; đóng app nặng khác (máy ảo, trình duyệt nhiều tab) |

## Tự build từ mã nguồn

Cần Xcode 16 trở lên (Swift 6). Để tạo lại model cần thêm [uv](https://docs.astral.sh/uv/) và Python 3.12.

```bash
uv run --python 3.12 --with torch --with coremltools --with numpy --with pillow tools/convert_models.py
```

```bash
uv run --python 3.12 --with torch --with coremltools --with numpy --with pillow --with spandrel python tools/convert_extra.py
```

```bash
PixGamma/scripts/build.sh --install
```

| Script | Tác dụng |
|---|---|
| `PixGamma/scripts/build.sh` | Build app và CLI, compile model, ký ad-hoc → `PixGamma/build/PixGamma.app`. `--install` chép vào /Applications và link `pixgamma` |
| `PixGamma/scripts/make_dmg.sh` | Tạo file cài đặt `PixGamma-<phiên bản>.dmg` và `.dmg.sha256` (bắt buộc cho tự cập nhật); `--recover` tạo thêm 2 file zip model Recover |
| `generative/convert_recover.sh` | Chuyển Realistic Vision 5.1 + ControlNet Tile sang Core ML cho Recover |
| `training/` | Sinh dữ liệu chữ, cấu hình fine-tune (traiNNer-redux trên GPU Mac), bộ chấm `eval_text.py` |

Nếu thư mục nằm trong vùng đồng bộ iCloud (ví dụ Desktop), các script tự đóng gói và ký ở thư mục tạm để tránh lỗi ký mã "detritus not allowed".

## Kiến trúc

```
PixGamma (Swift package)
├── PixGammaCore     engine: chia ô Core ML, chọn model, giữ màu, giữ chữ, phục hồi mặt,
│                  Recover (diffusion), phân tích Auto, đọc/ghi ảnh, HTTP API
├── pixgamma         CLI (swift-argument-parser)
└── PixGammaApp      app SwiftUI
```

| Thư mục | Nội dung |
|---|---|
| `PixGamma/Sources/` | Mã nguồn app, CLI và engine |
| `PixGamma/Models/` | Model Core ML (không nằm trong git) và [giấy phép model](PixGamma/Models/LICENSES.md) |
| `PixGamma/scripts/` | Build, cài đặt, đóng gói DMG |
| `tools/`, `generative/` | Chuyển trọng số PyTorch sang Core ML |
| `training/` | Dữ liệu, cấu hình fine-tune, bộ chấm |
| `docs/` | Thiết kế, nghiên cứu, ảnh mẫu, logo |

## Tài liệu

- [Nhật ký thay đổi](CHANGELOG.md)
- [Thiết kế và phân tích](docs/pixgamma-design.md): phân tích Real-ESRGAN và cách hiện thực từng tính năng
- [Nghiên cứu fine-tune](docs/finetune-research.md): kiến trúc, checkpoint, công cụ, công thức
- [Giấy phép model](PixGamma/Models/LICENSES.md)

## Model và ghi công

PixGamma dùng các model mã nguồn mở, đã chuyển sang Core ML:

- [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) (BSD-3-Clause), Xintao Wang và cộng sự
- [4xBHI_dat2_real](https://huggingface.co/Phips/4xBHI_dat2_real) (gốc của Photo v1 và Text v3), [2xNomosUni_span_multijpg_ldl](https://openmodeldb.info/models/2x-NomosUni-span-multijpg-ldl) và [4xNomosWebPhoto_RealPLKSR](https://openmodeldb.info/models/4x-NomosWebPhoto-RealPLKSR) (CC-BY-4.0), Philip Hofmann. Text v3 (dùng cho vùng chữ) là bản fine-tune của 4xBHI_dat2_real qua Photo v1, model chữ cũ là bản fine-tune của 4xNomosWebPhoto_RealPLKSR.
- [4x-UltraSharpV2](https://huggingface.co/Kim2091/UltraSharpV2) (CC-BY-NC-SA-4.0), Kim2091: gốc của model Photo (PixGamma Photo v3, v4, v6, v7). Trọng số các bản này chia sẻ theo cùng giấy phép, chỉ dùng phi thương mại.
- [GFPGAN](https://github.com/TencentARC/GFPGAN) (Apache-2.0), Tencent ARC
- [CodeFormer](https://github.com/sczhou/CodeFormer) (S-Lab License 1.0, **chỉ phi thương mại**), Shangchen Zhou và cộng sự
- Recover: [Realistic Vision V5.1](https://huggingface.co/SG161222/Realistic_Vision_V5.1_noVAE) và [ControlNet 1.1 Tile](https://huggingface.co/lllyasviel/control_v11f1e_sd15_tile) (CreativeML OpenRAIL-M), [sd-vae-ft-mse](https://huggingface.co/stabilityai/sd-vae-ft-mse) (MIT), chuyển bằng [ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion) của Apple

## Người đóng góp

| | Vai trò |
|---|---|
| **Steven Lam** ([@PhatLam1108](https://github.com/PhatLam1108)) | Tác giả: lên kế hoạch và định hướng sản phẩm, thiết kế kiến trúc, chọn, chuyển đổi và huấn luyện model AI, định hướng chất lượng ảnh, kiểm thử thực tế và phát hành |
| **Claude** ([Anthropic](https://www.anthropic.com/claude)) | Viết code theo kế hoạch và kiến trúc của Steven Lam, qua [Claude Code](https://claude.com/claude-code) |
| **Gemini** ([Google](https://deepmind.google/models/gemini/)) | Chỉnh giao diện, qua [Antigravity](https://antigravity.google) (Gemini 3.8, Gemini 4 Argon) |
| **Codex** ([OpenAI](https://openai.com/codex)) | Review code, góp ý về lỗi và bug |

Các commit viết cùng Claude có dòng `Co-Authored-By: Claude`.

## Giấy phép

Mã nguồn PixGamma: bảo lưu mọi quyền. Dùng miễn phí, phi thương mại. Mỗi model giữ giấy phép riêng của tác giả, xem [PixGamma/Models/LICENSES.md](PixGamma/Models/LICENSES.md).
