# Nhật ký thay đổi

Theo kiểu [Keep a Changelog](https://keepachangelog.com/vi/1.1.0/), đánh số [SemVer](https://semver.org/lang/vi/).
Bản 0.x là bản phát triển nội bộ, dùng miễn phí, phi thương mại.

## [Chưa phát hành]
### Tính năng mới
- **PixGamma Text v3 cho vùng chữ, thay Photo v1**: Photo v1 train thêm 10.000 vòng trên chữ tiếng Việt có dấu dày đặc (câu tiếng Việt và âm tiết ngẫu nhiên đủ 5 dấu thanh, 75% chữ nhỏ), giữ lật và xoay ảnh để lượt xoay 180 độ trong app vẫn có ích, không GAN (`training/configs/text_v3.yml`). Chấm cả quy trình chữ trong app: đọc đúng 92,4% ký tự (Photo v1: 91,0%), chữ có dấu đọc đúng 78,8% (76,6%), PSNR 30,4 dB (30,1), nét chữ 0,75 so với ảnh gốc (0,68). UltraSharpV2 chạy riêng: 90,0% và 72,4%. Giấy phép CC-BY-4.0 như Photo v1.
- Đã thử nhưng không dùng: Text v2 lấy gốc Photo v7, đọc tốt khi chạy riêng nhưng trong app không hơn Text v3 ở chữ có dấu (77,7%).
- **PixGamma Photo v7 thay Photo v6**: v6 train thêm 12.000 vòng trên cùng bộ dữ liệu, GAN tăng từ 0,03 lên 0,06 và DISTS từ 0,25 lên 0,3 (`training/configs/photo7.yml`). Bộ chi tiết mịn: DISTS ở ảnh sạch 2x 0,084 (v6: 0,090), tóc 0,086 (0,095), môi và da 0,078 (0,087); ảnh sạch 4x 0,101 (0,102); ảnh web 4x 0,172 (0,171). 40 ảnh web: 0,164 ở 4x như v6, 0,101 ở 2x (0,099). Sợi tóc, lông mày, nếp da rõ hơn ở ảnh sạch; ảnh web gần như không đổi.
- **PixGamma Photo v6 thay Photo v4**: v4 train thêm 12.000 vòng với tỉ lệ ô ảnh sạch tăng từ khoảng 17% lên 36% (thêm 2.668 ô lông thú CC0) và ô lông, tóc, da khoảng 21%; số ô ảnh web giữ nguyên (`training/configs/photo6.yml`). Bộ chi tiết mịn: DISTS ở ảnh sạch 2x 0,090 (v4: 0,094), ảnh sạch 4x 0,102 (0,104), ảnh web 4x giữ 0,171. 40 ảnh web: 0,164 ở 4x (0,167), 0,099 ở 2x (0,100). 8 ảnh sạch qua app ở 2x: 36,5 dB, SSIM 0,975, độ nét 0,92. Còn kém 4xNomos2_hq_dat2 ở ảnh sạch 2x (0,072) nhưng model đó tụt nhiều ở ảnh nén (0,245).
- Đã thử nhưng không dùng: Photo v5 lấy gốc 4xNomos2_hq_dat2 (CC-BY-4.0) với dữ liệu của v4, thua v4 ở hầu hết bài chấm (ảnh sạch 2x 0,098, ảnh web 0,181).
- **PixGamma Photo v4 làm model ảnh mặc định**: gốc là 4x-UltraSharpV2 (Kim2091, CC-BY-NC-SA-4.0), train trên ảnh của PixGamma thành Photo v3 (`training/configs/photo3_us2.yml`), rồi train thêm trên ảnh CC0 cận cảnh lông chim, tóc, lông mày, môi, da với GAN rất nhẹ 0,03 (`training/configs/photo4.yml`). Vùng chữ vẫn dùng Photo v1.
  - Bộ chấm chi tiết mịn mới (`training/eval_texture.py`, 25 vùng cắt CC0 không dùng để train), phóng 2x: DISTS 0,094, so với 0,099 của Photo v3, 0,123 của Photo v2 và 0,152 của UltraSharpV2. Độ chi tiết 0,85 so với ảnh gốc (v3: 0,68).
  - Tóc ở 4x: DISTS 0,108 so với 0,128 của v3, độ chi tiết 0,42 so với 0,31.
  - 40 ảnh web: DISTS 0,100 ở 2x (v2: 0,104), PSNR 35,1 dB (v2: 34,2).
  - Trọng số Photo v3, v4 dùng giấy phép CC-BY-NC-SA-4.0 như UltraSharpV2: miễn phí, phi thương mại, ghi công Kim2091 (`PixGamma/Models/LICENSES.md`).
- **PixGamma Photo v2** (đã thay bằng v4): Photo v1 train tiếp với GAN nhẹ.
- **Giao diện mới, Sáng và Tối**: ảnh chiếm cả cửa sổ, dock chọn chế độ và tỉ lệ, dải ảnh phía dưới, so sánh 100% và 200% chia đôi hoặc song song, xuất từng ảnh hoặc tất cả.
- **Recover hiểu nội dung ảnh**: Apple Vision mô tả ảnh làm prompt; Resemblance tự đặt 85 cho động vật, cây cỏ, chân dung, 40 cho ảnh khác; chốt an toàn cho biển hiệu, bản đồ, ảnh nhiều chữ (Creativity tối đa 0,3, khoá nét) và ảnh sản phẩm (tối đa 0,45).

### Thay đổi
- **Phóng 2x và 3x chạy Photo ở 4x rồi thu nhỏ** thay vì model SPAN 2x. 8 ảnh sạch thu nửa rồi phóng lại 2x: 35,4 dB, SSIM 0,966, độ nét 0,96 so với ảnh gốc (SPAN: 34,5 dB, 0,960, 0,70). Chậm hơn khoảng 1,8 lần; `PIXGAMMA_FAST_2X=1` giữ SPAN.
- Script chuyển model (`tools/convert_extra.py`) tự chia nhỏ nhóm lớp cuối của DAT khi vượt giới hạn FP16 (Photo v3, v4 lên tới khoảng 1,9 triệu); LayerNorm phía sau không đổi theo tỉ lệ nên kết quả giữ nguyên, Core ML lệch 0,25/255 so với PyTorch.

### Sửa lỗi
- **Bộ chấm chữ cho điểm nhảy và chấm sai một font**: chỉ 35 dòng chữ nên dịch ảnh 1 đến 3 px đã làm điểm dấu chênh tới 6 điểm, và font Trebuchet trên macOS không có chữ tiếng Việt (ảnh gốc hiện ô vuông). Nay mọi lần chấm lấy trung bình trên 8 cách dịch ảnh, Trebuchet thay bằng Georgia (`training/eval_text.py`, `training/eval_text_pipeline.py`).
- **Ghi đè ảnh gốc khi thư mục xuất là chính thư mục chứa ảnh**: file ra trùng tên và thay mất ảnh gốc. Nay đường dẫn ra được so với ảnh gốc (theo cả symlink, không phân biệt hoa thường) và thêm hậu tố `-pixgamma` khi trùng; app dùng chung cách đặt tên này.
- **Phục hồi khuôn mặt tô màu ảnh đen trắng**: ảnh đơn sắc giữ nguyên màu ở vùng mặt.

### Đổi tên
- **Pixora đổi tên thành PixGamma** (tên Pixora trùng nhiều app AI chỉnh ảnh khác), kèm logo mới hình ống kính có lá khẩu. App là `PixGamma.app`, lệnh là `pixgamma`, repo là `PhatLam1108/PixGamma`, model ảnh là PixGamma Photo v1. Bundle id giữ nguyên `vn.phatlam.pixora`.
- Giữ tương thích bản cũ: bản phát hành kèm thêm `Pixora-<version>.dmg` (chứa `Pixora.app`) để app 0.2.1 tự cập nhật được; bộ cập nhật mới chuyển `Pixora.app` thành `PixGamma.app` và trỏ lại các link lệnh `pixora`. Thư mục `Application Support/Pixora` (model đã compile, model Recover) tự chuyển sang `Application Support/PixGamma`. Lệnh `pixora` vẫn chạy (là tên khác của `pixgamma`), biến `PIXORA_*` vẫn được đọc khi không có `PIXGAMMA_*`.

### Sửa lỗi
- **Chữ thân nhỏ trên biển chụp ảnh bị vẽ thành chữ bịa** (vd biển đường mòn cc0_269 thu còn 500 px, chữ hoa ~4 px: "stolen cattle" thành "stolen cottle", "a region where" thành "a region uibere"): mọi model đều vẽ lại nét mờ, nhiễu hạt thành chữ giống chữ mà sai. Nay mỗi dòng chữ Vision tìm thấy được đo tỉ lệ tương phản mực/nhiễu nền (SNR): dòng nhỏ hơn 13 px có SNR thấp (biển chụp: 10–19; banner, màn hình, phím, biển tàu điện: 30–260) và nằm trong một đoạn văn thì chuyển sang bản phóng thường: mềm hơn nhưng đúng chữ trong ảnh. Bộ chấm chữ giữ nguyên (OCR 91,1%, PSNR 30,50 dB, độ nét 0,69); 6 ảnh thật 4x giữ nguyên hoặc nhỉnh hơn (cc0_269 +0,002 dB); lá cây, lông vẹt, giấy bạc, đường phố, chân dung: không đổi điểm ảnh nào.
- Chưa xử lý: chữ Vision không tìm thấy (vd chú thích ảnh ~2,5 px trên cùng biển, tương phản ~10 mức sáng trên nhiễu ~3). Vision không thấy chúng cả khi phóng bicubic 3x/4x; bộ dò nét chữ thử nghiệm bắt nhầm lá cây và nếp áo trước khi bắt được chú thích, nên đã bỏ.

### Thay đổi
- **Tự cập nhật không cần token GitHub nữa**: repo PixGamma đã công khai, nên app và `pixgamma update` đọc GitHub Releases và tải DMG mà không cần token. Token trong Keychain hoặc `PIXGAMMA_GITHUB_TOKEN` vẫn được dùng nếu có (nâng giới hạn từ 60 lên 5.000 lần mỗi giờ); hết lượt thì app báo rõ giờ thử lại và cho nhập token ở nút **Dùng token GitHub…**. `pixgamma update --token` vẫn còn, không bắt buộc.

## [0.2.1] - 2026-10-20
### Kiểm tra
- Chạy đủ các chế độ (Auto, Standard, High Fidelity, Art & CGI, Low Resolution, Recover, phục hồi mặt realistic/creative), tỉ lệ 1x–16x, `--width`/`--height`, mọi thanh tinh chỉnh, thiết bị gpu/ane/all/cpu, trên ảnh 1 px, 48 px, dải 2000 × 60, 3000 × 2000, ảnh xám, CMYK, nền trong suốt, palette, TIFF, WebP, HEIC; xuất PNG, JPEG, HEIC, TIFF. Tất cả chạy xong, giữ kênh trong suốt.

### Sửa lỗi
- **Chữ trên phím mềm và xiêu vẹo** (vd chữ Y): vùng chữ chạy bằng model Text v3, nay kém hơn PixGamma Photo v1 (v1 đã train cùng 2.500 ô chữ), và chữ nhỏ còn bị chuyển sang bản phóng mềm. Nay vùng chữ chạy bằng Photo v1 với 8 lượt lật/xoay, bỏ bước làm mềm chữ nhỏ (Photo v1 đọc đúng cả chữ hoa 3,6 px). Bộ chấm chữ: OCR 89,2% → 90,4%, PSNR 29,2 → 30,7 dB, độ nét 0,58 → 0,69; ảnh bàn phím thật +1,1 dB, quanh chữ Y +1,9 dB. `PIXGAMMA_TEXT_MODEL` chọn model khác cho vùng chữ khi chấm.
- **Vùng chữ chậm sau khi chuyển sang Photo v1**: 8 lượt lật/xoay của DAT2 làm ảnh bàn phím 480 px mất 37 giây ở 4x. Nay Photo v1 chạy 2 lượt (giữ nguyên + xoay 180°): 12 giây, đọc chữ còn tốt hơn (OCR 91,1% so với 90,4%), PSNR ảnh bàn phím 25,06 dB. `PIXGAMMA_TEXT_TTA=1|2|4|8` chọn số lượt.
- **Recover vẽ lại chữ trên phím** (vd A S D F G H J thành A S D Y G N I): Recover chỉ dò chữ trên ảnh gốc, nên bỏ sót từng chữ đơn trên phím rồi để diffusion vẽ lại. Nay dò như các chế độ khác (thêm lượt trên ảnh đã phóng): ảnh bàn phím màu giữ đúng mọi phím. Ảnh xám tương phản thấp vẫn có thể sót vài phím; khi đó tăng Resemblance trên 70 để khoá nét.
- **Recover bị macOS tắt ngang ở ảnh lớn** (vd 3436 × 5194): kết quả Core ML của từng ô diffusion không được giải phóng cho tới hết vòng khử nhiễu, bộ nhớ tăng theo số ô (28,6 GB ở 1440 px, 63,5 GB ở 2160 px). Nay mỗi ô chạy trong autoreleasepool: 8,5 GB ở 1440 px, ảnh 3436 × 5194 chạy xong với 10,2 GB trong 8 phút, kết quả giống hệt từng điểm ảnh.

### Đang làm
- **PixGamma Photo v2 (chưa dùng)**: v1 thêm GAN nhẹ (0,05) để tái tạo hạt vải và mặt phím (`training/configs/photo2.yml`, 12.000 vòng). Kết cấu nhỉnh hơn một chút nhưng PSNR kém v1 trên cả 6 ảnh thật (−0,1 đến −2,1 dB), vỡ chữ nhỏ và răng cưa ở viền phím, nên app vẫn dùng v1.

## [0.2.0] - 2026-10-20
### Cài đặt
- **File cài đặt DMG** (`PixGamma-0.2.0.dmg` ở trang Releases): kéo PixGamma vào Applications; có sẵn CLI và mọi model phóng ảnh. Kèm "Cài lệnh pixgamma (CLI).command" (link `pixgamma` vào PATH), "Cài model Recover.command" và hướng dẫn ngắn. Script đóng gói: `PixGamma/scripts/make_dmg.sh`.
- **Tự cập nhật**: app kiểm tra GitHub Releases mỗi ngày một lần và ở menu PixGamma → Kiểm tra cập nhật…; hiện ghi chú phát hành, tải DMG, chỉ cài khi mã SHA-256 khớp và app bên trong đúng bundle id và phiên bản, thay app rồi tự mở lại (nếu lỗi giữa chừng thì trả lại bản cũ). Repo riêng tư nên cần token GitHub chỉ đọc, cất trong Keychain. CLI: `pixgamma update [--install] [--token]`.
- **Model Recover phát hành riêng** thành 2 file zip (~2,7 GB, vượt giới hạn 2 GB mỗi file của GitHub), cài vào `~/Library/Application Support/PixGamma/Models/Recover`.
- **Chung một số hiệu phiên bản** cho app, CLI, API và file cài đặt (`APIServer.version`).
- README tiếng Việt và tiếng Anh viết lại: cài đặt, gỡ cài đặt, yêu cầu máy, bảng cờ CLI, tham số API, xử lý sự cố.

### Tính năng mới
- **Chế độ Recover: tái tạo điểm ảnh bằng diffusion** (giống kiểu tạo sinh của các upscaler thương mại). Phóng bằng RealESRNet làm nền sạch, rồi Realistic Vision 5.1 (SD 1.5) + ControlNet Tile vẽ lại da, lỗ chân lông, sợi tóc, lông thú, chạy hoàn toàn bằng Core ML trên GPU.
  - Chia ô kiểu MultiDiffusion: mọi ô được trộn ở từng bước khử nhiễu trên một canvas latent chung, không lộ đường nối.
  - Bộ lấy mẫu DPM++ 2M SDE tự viết (sigma Karras): chi tiết mịn, không kết cụm.
  - Lượt riêng cho mắt và lông mày: cắt từng mắt, phóng lên 512 px, vẽ lại mống mắt, lông mi, đốm sáng rồi trộn mềm.
  - Prompt theo vùng: ô trên da mặt dùng prompt da (ControlNet chặt hơn, giữ phẳng vài bước đầu, làm sạch da nền bằng guided filter), ô còn lại dùng prompt tóc, vải. Prompt không nhắc mắt hay khuôn mặt, nên không mọc mắt thừa trên má; negative prompt chặn tóc rối, sợi tóc lạc ra nền, giọt nước.
  - Thanh Creativity (độ vẽ lại) và Resemblance (độ bám ảnh gốc, cao thì khoá cấu trúc để không bịa chữ). CLI `-m rec --cr --rs --prompt`, API `mode=recover&creativity=&resemblance=`.
  - Ảnh 1536 px khoảng 35 giây trên M2 Ultra.
- **Model Photo mới: 4xBHI_dat2_real (DAT2, Phhofm, CC-BY-4.0)**, thay 4xNomosWebPhoto. Chấm 10 model 4x công khai được đánh giá cao (Hugging Face, OpenModelDB, GitHub) trên 40 ảnh thật (22 ảnh laptop, chân dung, động vật; `training/evaluate.py`): DAT2 đứng đầu, DISTS 0,173 và PSNR 29,0 dB, so với 0,199 và 26,9 dB của Nomos. Nomos vẽ vân giả lên hình nền, phím và lông thú; DAT2 giữ đúng chất liệu. Chậm hơn khoảng 5 lần mỗi ô (0,43 giây ô 256 px trên M2 Ultra), chỉ dùng khi phóng trên 2x (2x vẫn dùng SPAN, tốt nhất ở mức này). Chạy GPU; không chạy trên Neural Engine (biên dịch không xong), PixGamma tự chuyển sang GPU khi chọn `ane` hoặc `all`.
- **PixGamma Photo v1, model ảnh chụp riêng của PixGamma** (thay 4xBHI_dat2_real làm model Photo): DAT2 fine-tune 15.000 vòng từ 4xBHI_dat2_real trên ảnh CC0 đã lọc (chuỗi thu nhỏ + nén JPEG hai lần) và 2.500 ô chữ tự sinh, loss Charbonnier + MS-SSIM + LDL + focal frequency + DISTS, không GAN để không vẽ vân giả (`training/configs/photo1.yml`). Trên 40 ảnh chấm (không có trong dữ liệu train), phóng 4x: PSNR 30,5 dB (DAT2 gốc 29,0), DISTS 0,165 (0,173). DAT2 gốc làm ảnh sáng lên khoảng 1 mức xám và ngả màu ở vùng tối (phím vàng, da thuộc); v1 gần như không lệch màu (−0,06). Chạy cả pipeline trên ảnh laptop, da, vải: PSNR cao hơn ở cả 6 ảnh (+0,3 đến +3,7 dB). Cùng kiến trúc nên tốc độ như DAT2.
- **Nhận diện chữ tiếng Việt**: Vision nhận diện chính xác `vi-VT` + `en-US`, đọc đủ dấu; dò thêm một lượt trên ảnh phóng 2x và trên ảnh đã phóng để bắt chữ nhỏ. Chữ đọc được ghi vào báo cáo (`text` trong JSON).
- **Model chữ riêng (Text)**, RealPLKSR fine-tune từ 4xNomosWebPhoto qua ba vòng:
  - v1: 8.000 vòng trên 8.000 ô chữ tự sinh và ảnh chụp, thay RealESRNet trong vùng chữ.
  - v2: 12.000 vòng trên 12.000 ô mới: 60% chữ nhỏ (cao 3–10 px ở ảnh nhỏ), âm tiết tiếng Việt sinh ngẫu nhiên phủ đủ tổ hợp dấu (bộ cũ chỉ có 12 câu cố định), ảnh web thu nhỏ và nén JPEG hai lần.
  - v3: 8.000 vòng thêm loss tần số cao (focal frequency), độ sắc cạnh (gradient variance) và nét vẽ (line distiller), không dùng GAN để model không bịa nét.
  - Trên bộ chấm (`training/eval_text.py`: 5 font, câu chưa thấy khi train): độ nét so với ảnh gốc 0,73 (v1 0,54); chữ hoa 4,3 px đọc đúng 85,9% (bicubic 69,2%).
- **Nét chữ thẳng hơn**: vùng chữ chạy model 8 lượt lật/xoay rồi lấy trung bình, độ gợn ngẫu nhiên ở nét mảnh triệt tiêu nhau (OCR 88,9% → 90,3%, PSNR +0,5 dB).
- **Chữ quá nhỏ không bị vẽ thành chữ khác**: với chữ hoa khoảng 3,6 px ở ảnh gốc, dấu thanh chưa tới 1 điểm ảnh và model vẽ ra chữ sắc nhưng sai. PixGamma đo độ trải dọc của mực chữ từng dòng ngay trên điểm ảnh (hộp chữ của Vision lệch 1–2 px ở cỡ này) và chuyển những dòng đó sang bản phóng trung thực: mềm hơn nhưng đúng chữ. Đã thử dựng lại chữ nhỏ bằng font theo cách đọc của Vision và giữ khi khớp điểm ảnh, nhưng bỏ vì cách đọc sai khớp ảnh gần bằng cách đọc đúng.
- **Bộ dữ liệu chữ tự sinh** (`training/make_text_dataset.py`): 114 font có tiếng Việt, banner, nhãn, bàn phím, nền ảnh thật; tùy chọn `--small`, `--chain`, `--thin` (chữ trắng nét mảnh trên nền banner).
- **Bộ chấm chữ**: `training/eval_text.py` (model) và `training/eval_text_pipeline.py` (cả pipeline): OCR theo từng dòng và từng cỡ chữ, PSNR, độ nét quanh nét chữ.
- **Khử viền sáng (halo)** quanh cạnh tương phản cao, ví dụ chữ tối trên màn hình sáng: mỗi pixel output bị giới hạn trong khoảng sáng tối của vùng lân cận ở ảnh gốc (cộng một biên nhỏ), nên phần vượt ngưỡng do model thêm vào bị cắt, còn kết cấu thật như lông, da vẫn giữ. Mặc định 80, chỉnh bằng `--dh` / `dehalo=`.
- **Dữ liệu ảnh chụp** (`training/prepare_dataset.py --chain --exclude`): chuỗi thu nhỏ + nén JPEG hai lần, bỏ ảnh dùng để chấm, tranh vẽ và ảnh nhạy cảm (`training/configs/photo_exclude.txt`).
- **Bộ ảnh test thực tế**: 22 ảnh sản phẩm Lenovo 584–800 px (chỉ dùng trên máy, không đưa lên repo) để kiểm tra Auto và chất lượng ở 2x.

### Sửa lỗi
- **Cuối dòng chữ nhỏ bị vỡ khối**: Vision hay dừng sớm vài chữ ở dòng chữ nhỏ, phần còn lại giữ output của model ảnh. Nay vùng chữ được nối dài theo mực chữ tới hết dòng.
- **Bộ chấm OCR cho điểm nhiễu**: Vision đọc một dòng khác đi tùy dòng bên cạnh, nên dòng giống hệt từng điểm ảnh vẫn bị chấm khác. Nay mỗi dòng được cắt riêng rồi mới đọc.
- **CLI `pixgamma` gọi từ PATH báo không tìm thấy model**: đường dẫn file chạy lấy từ argv[0] (chỉ là "pixgamma"), nên không tìm được thư mục model trong app. Nay dùng đường dẫn tuyệt đối.
- **Chữ mềm và có quầng sáng sau khi giữ chữ**: bước giữ màu gốc lấy lại màu từ ảnh nguồn (đã mờ, nhiễu JPEG quanh nét) và phủ lên chữ vừa dựng lại. Nay bước này bỏ qua vùng chữ.
- **Auto chọn nhầm Art & CGI cho ảnh sản phẩm nền trắng** (22/22 ảnh Lenovo): nền studio bị tính là mảng phẳng. Nay Auto bỏ qua các pixel giống màu nền ở viền ảnh, và chỉ coi là tranh vẽ khi phần không phẳng chủ yếu là nét viền cứng (render 3D và ảnh chụp chuyển sáng tối mượt). Kết quả: 22/22 ảnh dùng model ảnh thật.
- **Thay model cùng tên nhưng app vẫn chạy bản cũ**: bản compile trong Application Support chỉ được nhận diện theo tên và ngày sửa của symlink. Nay mỗi bản compile kèm dấu vân tay của gói nguồn (đường dẫn thật, ngày và cỡ của manifest và trọng số), nên đổi sang bộ model khác hay model fine-tune sẽ tự compile lại.
- **Chi tiết đen của laptop trông sáng và đục hơn sau khi phóng**: Auto tự bật làm nét 30% (vì đo độ nét trên cả nền trắng), tương phản 30% và hạt 25%, cộng với việc các ô chữ nhỏ dính nhau thành một vùng phủ cả ảnh. Nay Auto không tự làm nét, không thêm tương phản hay hạt (người dùng vẫn bật tay được), và bỏ qua vùng chữ lớn hơn 20% khung hình.

### Đang làm
- **Model chữ v4 (chưa dùng)**: train thêm 8.000 vòng với chữ trắng nét mảnh trên nền banner (`training/configs/text4.yml`, `make_text_dataset.py --thin 0.5 --chain 0.6`). Nét hơn v3 (0,77 so với 0,73) nhưng đọc chữ hoa 4,3 px kém hơn (83,2% so với 85,9%), nên app vẫn dùng v3.
- **Fine-tune model riêng cho ảnh sản phẩm laptop**: môi trường traiNNer-redux chạy trên GPU Mac (MPS, torch 2.14.1). Kế hoạch hai pha (fidelity rồi GAN nhẹ), tăng trọng số loss ở vùng chữ phím, sinh ảnh LR offline mô phỏng ảnh web. Chi tiết ở [docs/finetune-research.md](docs/finetune-research.md).
- **Chạy thử pha 1 thành công trên GPU Mac**: `training/train_mps.py` thay các lệnh gọi CUDA của traiNNer-redux bằng MPS, cấu hình mẫu ở `training/configs/phase1_trial.yml` (Charbonnier + MS-SSIM + LDL + Sobel). Với 64 ảnh CC0/public domain (2272 ô), batch 8, ô LR 64 px: khoảng 1,6 vòng/giây trên M2 Ultra, 200 vòng mất 2 phút. PSNR val tăng từ 26,7 lên 29,9 dB. `tools/convert_extra.py` xuất được checkpoint fine-tune sang Core ML (`PIXGAMMA_PHOTO_WEIGHTS`, `PIXGAMMA_OUT_DIR`), sai khác so với PyTorch 0,25/255.

## [0.1.0] - 2026-10-18
### Tính năng mới
- **App macOS SwiftUI** bố cục 3 cột: danh sách ảnh (kéo thả ảnh hoặc thư mục), khung xem trước có thanh so sánh trước/sau kéo được và 3 mức zoom, bảng tinh chỉnh bên phải. Giao diện tối màu graphite, một màu nhấn, thẻ chọn model. Xem trước chạy trên vùng giữa ảnh để thử thiết lập nhanh.
- **5 chế độ AI** chạy bằng Core ML:
  - Auto: tự đo nhiễu (Immerkær), độ nét (phương sai Laplacian), khối JPEG, mảng phẳng và số khuôn mặt, rồi chọn model và độ mạnh.
  - Standard: RealPLKSR 4xNomosWebPhoto và SPAN 2xNomosUni, huấn luyện trên ảnh chụp thật, tái tạo kết cấu lông, da, vải. Real-ESRGAN x4plus/x2plus làm dự phòng.
  - High Fidelity: RealESRNet trung thực, không bịa chi tiết. Thanh Detail trộn thêm chi tiết từ model Standard.
  - Art & CGI: Real-ESRGAN anime_6B.
  - Low Resolution: realesr-general-x4v3, thanh khử nhiễu liên tục (trộn trọng số với bản wdn ngay trong mạng).
- **Phóng theo tỉ lệ 1–16x, theo chiều rộng hoặc chiều cao.** Chọn mức gốc 2x/4x nhỏ nhất đủ dùng, chồng nhiều lượt khi trên 4x, rồi resize Lanczos.
- **Chia ô không lộ viền**: ô 256 px, mỗi phía 16 px ngữ cảnh, chỉ giữ phần giữa ô.
- **Giữ màu gốc**: trả lại màu và tông tần số thấp của ảnh gốc sau khi phóng, để model không làm lệch màu.
- **Giữ chữ** (phím laptop, nhãn, màn hình): Apple Vision dò chữ, vùng chữ được dựng lại bằng model trung thực RealESRNet (không bịa nét) rồi trộn mềm vào ảnh. Nét chữ thẳng, mảnh, không bị model GAN "vẽ" lại.
- **Phục hồi khuôn mặt** hai kiểu: Chân thực (CodeFormer, có thanh giữ nét mặt gốc) và Sáng tạo (GFPGAN v1.4). Căn mặt theo 5 điểm mốc của Vision, dán lại bằng mặt nạ mềm, cân màu da theo ảnh gốc.
- **Tinh chỉnh**: khử nhiễu, làm nét, khử nén JPEG, tương phản cục bộ và độ rực, kết cấu hạt tự nhiên (tránh da "nhựa"). Mọi độ mạnh theo thang 0–100.
- **Ảnh có nền trong suốt**: kênh alpha được phóng riêng rồi ghép lại.
- **Xuất file** PNG, JPEG, TIFF (nén ZIP), HEIC hoặc giữ định dạng gốc. Giữ EXIF/GPS/IPTC, ghi DPI, đặt tiền tố/hậu tố tên file, không bao giờ ghi đè ảnh gốc.
- **CLI `pixgamma`**: `upscale` (hàng loạt, đệ quy thư mục, bỏ qua file đã có, xuất JSON), `analyze`, `models`, `serve`. Cờ ngắn gọn (`-m std`, `--dn`, `--sh`, `--fr`, `--am`, `--se`…).
- **HTTP API cục bộ** (`pixgamma serve`, mặc định `127.0.0.1:8765`): `/health`, `/v1/models`, `/v1/analyze`, `/v1/upscale`. Trả ảnh kèm báo cáo trong header `X-PixGamma-Report`, hoặc JSON có ảnh base64. Bật/tắt được ngay trong app.
- **Ưu tiên GPU Apple Silicon**: mặc định chạy GPU. Đo trên Mac Studio M2 Ultra với model Standard: GPU 1.8 giây, Neural Engine 3.9 giây.
- **Đóng gói**: `scripts/build.sh` build bản release, compile model, ký ad-hoc và tạo `PixGamma.app` có sẵn CLI bên trong. Đóng gói và ký ở thư mục tạm để tránh lỗi "detritus" của iCloud Desktop.

### Sửa lỗi
- Chữ trên phím bị đậm và cong queo: thử nghiệm ép tương phản về hai mức mực/nền làm phình nét (viền anti-alias bị đẩy về phía chữ) và khuếch đại độ lượn của khối JPEG; bộ dò chữ theo tương phản còn nhận nhầm lá cây, bokeh, lông chim thành chữ. Đã bỏ cả hai, giữ cách dựng vùng chữ bằng model trung thực.
- Model trộn trọng số động (High Fidelity bản đầu) bị treo vô hạn trên GPU (MPSGraph chờ semaphore). Đã thay bằng model cố định, thanh Detail trộn output thay vì trộn trọng số.
- Auto chọn nhầm Low Resolution cho mọi ảnh nhỏ hơn 600 px, nên chỉ làm sạch mà không tái tạo kết cấu. Nay chỉ chọn Low Resolution khi ảnh thật sự nhiều nhiễu.
- Giao diện bản đầu bị vỡ: thanh trượt lệch khỏi nhãn trong cột hẹp, khung giữa trống khi chưa xem trước. Đã làm lại toàn bộ.

### Nghiên cứu
- Phân tích Real-ESRGAN và cách hiện thực từng tính năng, ghi trong [docs/pixgamma-design.md](docs/pixgamma-design.md).
- Khảo sát kiến trúc nhẹ, checkpoint ảnh thật, công cụ huấn luyện và công thức fine-tune: [docs/finetune-research.md](docs/finetune-research.md).
