# PixGamma — thiết kế

PixGamma là app phóng to ảnh bằng AI cho macOS (Apple Silicon), gồm app SwiftUI,
CLI `pixgamma` và HTTP API (`pixgamma serve`). PixGamma chỉ chạy model mã nguồn mở và
model tự fine-tune, chuyển sang Core ML.

## 1. Phân tích Real-ESRGAN

| Khía cạnh | Real-ESRGAN làm gì |
|---|---|
| Model | RRDBNet x4plus / x2plus (pixel-unshuffle), anime_6B, SRVGGNetCompact general-x4v3 (+ wdn) |
| Khử nhiễu | DNI: nội suy trọng số `d·x4v3 + (1−d)·wdn` → `--denoise_strength` liên tục |
| Chia ô | `--tile` + `--tile_pad 10` + `--pre_pad`, ghép bằng cách cắt viền |
| Alpha | Upscale kênh alpha riêng (bằng model hoặc nội suy) |
| Tỉ lệ tuỳ ý | Chạy ở mức gốc rồi resize (`--outscale`) |
| Khuôn mặt | GFPGAN v1.4: facexlib dò mặt → căn 512 → khôi phục → dán lại bằng mask |
| 16-bit, ảnh xám | Có |
| Hạn chế | Không có GUI, không auto, không giữ màu, viền ô cứng, chỉ chạy PyTorch/ncnn |

## 2. Tính năng và cách hiện thực

| Tính năng PixGamma | Kỹ thuật | Cách hiện thực |
|---|---|---|
| Chế độ Standard / Art & CGI / Low Res / Standard 2x | Chế độ theo loại ảnh | RealESRGAN x4plus, anime_6B, general-x4v3(+wdn), x2plus → Core ML FP16 |
| Thanh khử nhiễu liên tục | DNI của Real-ESRGAN | Model Low Res nhận input `denoise` 0..1, trộn trọng số ngay trong mạng |
| Làm nét, khử nén | Hậu xử lý thông thường | Hậu xử lý Core Image (unsharp mask có kiểm soát; deblock trước khi chạy model) |
| Auto | Phân tích ảnh | Ước lượng noise (MAD của Laplacian), độ mờ, blockiness JPEG → chọn model và tham số |
| Giữ màu gốc | Giữ màu tần số thấp | Thay thành phần màu tần số thấp của output bằng của ảnh gốc (YCbCr, Gaussian) |
| Ghép ô không lộ viền | tile_pad của Real-ESRGAN | Ô 256, mỗi phía 16 px ngữ cảnh, chỉ giữ phần giữa ô |
| High Fidelity + thanh Detail | Network interpolation (ESRGAN) | RealESRNet ↔ RealESRGAN trộn trọng số theo input `detail` |
| Giữ chữ (phím laptop, nhãn) | Apple Vision | Vision dò chữ → vùng chữ dùng output trung thực (detail = 0), trộn mềm |
| Tương phản & màu | Clarity và vibrance | Unsharp mask bán kính lớn (clarity) + vibrance |
| Kết cấu (Texture) | Film grain | Thêm hạt luminance theo vùng sáng/tối, tránh da "nhựa" |
| Mặt chân thực / sáng tạo | CodeFormer, GFPGAN | CodeFormer (thanh fidelity) / GFPGAN, cân màu da theo ảnh gốc |
| Mức 2x/4x gốc + tỉ lệ tuỳ ý / theo chiều rộng/cao | Real-ESRGAN (`--outscale`) | Chọn mức gốc nhỏ nhất ≥ tỉ lệ yêu cầu (chạy nhiều lượt nếu > 4x), rồi resize Lanczos |
| Phục hồi khuôn mặt + độ mạnh | GFPGAN | Vision dò 5 điểm mốc → căn FFHQ 512 → GFPGAN Core ML → dán lại bằng mask feather, trộn theo strength |
| Alpha | Real-ESRGAN | Tách alpha, resize Lanczos, ghép lại |
| Chọn thiết bị | Core ML compute units | Mặc định GPU (nhanh nhất trên M2 Ultra, đo: Standard 1.8s GPU vs 3.9s ANE); `--device gpu|all|ane|cpu` |
| CLI đầy đủ, batch, đệ quy, prefix/suffix, skip-existing | Công cụ dòng lệnh thông thường | `pixgamma upscale …` dùng các cờ tương tự |
| API | — | `pixgamma serve`: HTTP JSON + nhị phân trên localhost |
| So sánh trước/sau | Giao diện thông thường | Thanh trượt split view, zoom, pan |

Chưa làm: đọc RAW.

## 3. Kiến trúc

```
PixGamma/
  Package.swift
  Models/*.mlpackage          (nguồn, tạo bởi tools/convert_*.py)
  Sources/PixGammaCore/         engine dùng chung cho app, CLI và API
  Sources/pixgamma/             CLI + HTTP server
  Sources/PixGammaApp/          app SwiftUI
  scripts/build.sh            build, compile model, đóng gói PixGamma.app
```

Các thư mục tìm model, theo thứ tự: `$PIXGAMMA_MODELS` →
`PixGamma.app/Contents/Resources/Models` → `~/Library/Application Support/PixGamma/Models`.
