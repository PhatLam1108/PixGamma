# Pixora — Nghiên cứu fine-tune mô hình SR trên ảnh sản phẩm laptop

*Cập nhật: 18/10/2026. Phạm vi: chọn kiến trúc, checkpoint gốc, toolkit, công thức loss/dataset, chế độ diffusion về sau, và kế hoạch cụ thể cho M2 Ultra + Core ML.*

Ký hiệu độ tin cậy: **[đã kiểm]** là thông tin đọc trực tiếp từ repo hoặc metadata OpenModelDB. **[ước tính]** là suy luận hoặc ước lượng, cần đo lại trên máy thật.

---

## TL;DR

- **Chọn chính:** kiến trúc **RealPLKSR**, bản `pixelshuffle` + `layer_norm: true` (~7,4M tham số, toàn conv, không có attention). Đây là lựa chọn chất lượng cho ảnh thật, dễ chuyển Core ML. Trên RTX 4090, mô hình này còn **nhanh hơn khoảng 2,5 lần** so với RRDBNet x4plus đang dùng (9–11 so với 3,5–4,8 fps ở input 640×480 fp16) [đã kiểm, benchmark traiNNer-redux].
- **Chọn phụ (chế độ nhanh):** **SPAN** (~2,6M tham số, Apache-2.0, giải nhất NTIRE 2024 Efficient SR), nhanh gấp khoảng 7–9 lần RealPLKSR.
- **Checkpoint khởi đầu:** `4xNomosWebPhoto_RealPLKSR` hoặc `4xNomos2_realplksr_dysample` (Philip Hofmann / Helaman, CC-BY-4.0, train cho ảnh chụp). Pretrain fidelity: `4x_realplksr_mssim_pretrain` (musl, CC0).
- **Toolkit:** **traiNNer-redux** (Apache-2.0, còn phát triển, có sẵn template RealPLKSR/SPAN, LDL/DISTS/MS-SSIM/HSLuv). Code đang hard-code `cuda`/`cpu`, nên **cần vá vài dòng để chạy MPS**. neosr đòi CUDA ≥ 12.4, không dùng được trên Mac.
- **Nguyên nhân chính gây "sắc giả":** config gốc của Real-ESRGAN bật **USM sharpen trên GT** (`l1_gt_usm`, `percep_gt_usm: True`), tức là dạy mô hình làm nét quá tay. Thêm vào đó là trọng số perceptual dồn vào `conv5_4` và GAN 0.1. Khi fine-tune cần **tắt USM**, hạ GAN xuống 0.02–0.05, bật LDL, ưu tiên DISTS, và nội suy mạng với bản fidelity.
- **Lưu ý license:** **CodeFormer** đang dùng là S-Lab License (chỉ cho mục đích **phi thương mại**). Nên kiểm tra nếu Pixora sẽ bán.

---

## 1. Kiến trúc ứng viên

Số liệu dưới đây lấy từ bảng benchmark của traiNNer-redux (`docs/source/benchmarks.md`): input 4x 480×640, RTX 4090, fp16 (bf16 cho transformer), PSNR Urban100 với DF2K [đã kiểm].

| Kiến trúc | Params | FPS 4090 (CL) | PSNR DF2K | Core ML | Ghi chú |
|---|---:|---:|---:|---|---|
| Compact (SRVGG, đang dùng) | 0,62M | 227 | – | Rất dễ | Nhanh nhưng dung lượng mô hình thấp, dễ bết chi tiết |
| SPAN | 2,6M | 82 | 26,18 | Dễ (conv + sigmoid attention; conv3XC gộp được khi eval) | Apache-2.0; NTIRE24 ESR #1 |
| MoSR | 4,3M | 12 | – | Khá dễ (conv/GatedCNN) | MIT; có 4xNomos2_hq_mosr nhưng train cho input *không* suy giảm |
| ESRGAN-lite | 5,0M | 13 | – | Dễ | Ít checkpoint ảnh thật |
| **RealPLKSR** (LN, pixelshuffle) | 7,4M | 11 | 26,94 | Dễ (conv 17×17, Mish, LN) | MIT (repo PLKSR gốc); rất nhiều model ảnh |
| OmniSR | 0,8M | 7,7 | 26,95 | Trung bình (attention theo cửa sổ) | Repo không có file LICENSE |
| RRDBNet x4plus (đang dùng) | 16,7M | 4,8 | 27,03 | Dễ | BSD-3 |
| SwinIR-S | 0,93M | 1,1 | 26,47 | Khó (window partition, shift, mask, relative pos) | Apache-2.0 |
| ATD-light | 0,81M | 1,0 | 26,97 | Khó (token dictionary + attention) | Apache-2.0 |
| DAT-light / DAT-S | 0,9M / 11,2M | 0,6 | 26,64 / 27,68 | Khó (spatial + channel attention, kích thước động) | Apache-2.0 |
| HAT-S | 9,6M | 0,64 | 27,87 | Khó, VRAM 9,85 GB | Apache-2.0 |

**Lưu ý khi chuyển Core ML:**
- Các mô hình transformer (SwinIR/HAT/DAT/ATD) thường cần pad lên bội số của window, reshape/permute nhiều và có mask attention. coremltools *có thể* convert được với tile cố định 256, nhưng chậm hơn khoảng 10 lần so với CNN cùng chất lượng, và rủi ro tràn số fp16 trong softmax cũng cao hơn. Không nên chọn cho máy Mac.
- **RealPLKSR + DySample** dùng `grid_sample`. Trong chaiNNer, file .pth của bản dysample không chạy được: tác giả phải phát hành thêm ONNX static 256 [đã kiểm, model card HF]. Với Core ML, `grid_sample` map sang op `resample` (iOS16+/macOS13+), nhưng chưa có ai xác nhận chạy được [chưa kiểm]. **Ưu tiên `pixelshuffle`.**
- **GroupNorm và tile:** khi `layer_norm: false`, RealPLKSR dùng GroupNorm, vốn thống kê trên toàn H×W của từng tile. Vì vậy tile 256 cho kết quả khác chạy cả ảnh, có thể sinh lệch tông giữa các tile [suy luận từ code]. LayerNorm trong bản `layer_norm: true` chuẩn hóa theo từng pixel (theo kênh) nên an toàn khi tile, và theo benchmark còn nhanh hơn (10,9 so với 6,4 fps).
- `PLKConv2d` ở chế độ eval gán in-place `x[:, :idx] = conv(...)`. Khi trace, nên vá thành `split → conv → cat` (giống nhánh training) để coremltools tạo graph sạch [đã kiểm code].

### Checkpoint ảnh thật trên OpenModelDB (metadata đọc từ repo `OpenModelDB/open-model-database`) [đã kiểm]

| Model | Arch | Scale | License | Dataset / ghi chú |
|---|---|---|---|---|
| 4xNomosWebPhoto_RealPLKSR | realplksr (64dim, 28nb, 17ks) | 4 | CC-BY-4.0 | Nomos-v2; noise thực, lens blur, nén lại jpg+webp; pretrain = realplksr_gan_pretrain. Phát hành trước khi có tùy chọn LN, **nhiều khả năng dùng GroupNorm** |
| 4xNomos2_realplksr_dysample | realplksr + dysample | 4 | CC-BY-4.0 | Nomos-v2, JPEG đến q70 |
| 4xmssim_realplksr_dysample_pretrain | realplksr | 4 | CC-BY-4.0 | Pretrain fidelity (MS-SSIM) |
| 4x_realplksr_mssim_pretrain / 4x_realplksr_gan_pretrain | realplksr | 4 (có cả 2x) | **CC0** | musl; chỉ downsample, là điểm khởi đầu "sạch" |
| 4xRealPLKSR-Pretrain-V4 | realplksr | 4 | CC0 | Kim2091 |
| 4xPurePhoto-RealPLKSR / -span | realplksr / span | 4 | CC-BY-SA-4.0 | 6.500–8.684 ảnh chọn tay; SA buộc chia sẻ lại cùng license |
| 4xNomos8k_span_otf_weak/medium/strong | span | 4 | CC-BY-4.0 | Ảnh chụp, degradation OTF ba mức |
| 2xNomosUni_span_multijpg(_ldl) | span | 2 | CC-BY-4.0 | 2x, JPEG đến q40, có bản LDL, giữ được DoF |
| 2xNomosUni_compact_otf_medium | compact | 2 | CC-BY-4.0 | Thay được trực tiếp cho Compact hiện tại |
| 4xNomosWebPhoto_esrgan | esrgan 23nb | 4 | CC-BY-4.0 | Fine-tune từ x4plus, so A/B ngay được |
| 4xRealWebPhoto_v4_dat2, 4xNomosWebPhoto_atd, 4xNomos8kSCHAT-S | dat/atd/hat | 4 | CC-BY-4.0 | Chất lượng cao, quá nặng cho Core ML |
| 4xClearRealityV1 (span), 4xUltraSharpV2 (DAT2) | – | 4 | **CC-BY-NC-SA** | Phi thương mại, tránh dùng |
| 2xText2HD_v.1 (realplksr) | realplksr | 2 | CC-BY-SA-4.0 | Train trên sách/chữ scan, có thể tham khảo cho mảng chữ |

CC-BY-4.0 yêu cầu **ghi công** (ví dụ trong màn About/Credits của Pixora). Một số dataset gốc (Nomos-v2, Nomos8k) chưa xác định rõ license [chưa kiểm]. Mô hình fine-tune lại là sản phẩm phái sinh của checkpoint, nên dùng CC0 hoặc CC-BY là an toàn nhất.

**Khuyến nghị:** (1) **RealPLKSR LN pixelshuffle** cho chế độ chất lượng; (2) **SPAN** cho chế độ nhanh hoặc preview. Cả hai thuần CNN, tile-safe và có sẵn checkpoint ảnh chụp với license mở.

---

## 2. Toolkit huấn luyện

| Toolkit | License | Dataset | MPS | Ghi chú |
|---|---|---|---|---|
| **traiNNer-redux** ([repo](https://github.com/the-database/traiNNer-redux)) | Apache-2.0, push 10/2026 | Paired (`pairedimagedataset`) hoặc HR-only + OTF (`realesrgandataset`, `high_order_degradation: true`) | **Không chính thức.** `base_model.py:47` để `device = "cuda" if num_gpu else "cpu"`; GradScaler/autocast gắn `device="cuda"`; prefetcher dùng `torch.cuda.Stream`; `flip_loss` và `perceptual_anime_loss` gọi `.cuda()` | Có template `RealPLKSR_{fidelity,gan,OTF_fidelity,OTF_gan}.yml`, SPAN, Compact…; loss gồm LDL, DISTS, MS-SSIM, HSLuv, Sobel, FF; xuất ONNX được |
| neosr ([repo](https://github.com/neosr-project/neosr)) | Apache-2.0 | Paired + OTF | **Không**, "Requires CUDA >= 12.4" | Nhiều loss (consistency, FDL-DINOv2, MS-SWD). Đọc để lấy ý tưởng |
| BasicSR / Real-ESRGAN ([Training.md](https://github.com/xinntao/Real-ESRGAN/blob/master/docs/Training.md)) | Apache-2.0 / BSD-3 | `finetune_realesrgan_x4plus.yml` (HR-only, OTF bậc 2) hoặc `_pairdata.yml` (meta_info qua `generate_meta_info_pairdata.py`) | Phải vá: device cuda/cpu, các module jpeger/USM gọi `.cuda()` | Đã cũ (push lần cuối 2024). Config mặc định: gt_size 256, batch 12, lr 1e-4, L1 1.0, perceptual 1.0 (conv1_2/2_2 0.1, conv3_4/4_4/5_4 1.0), GAN 0.1, **l1_gt_usm/percep_gt_usm True**, total 400k |
| chaiNNer ([repo](https://github.com/chaiNNer-org/chaiNNer)) + **spandrel** ([repo](https://github.com/chaiNNer-org/spandrel)) | GPL-3.0 / **MIT** | – | chaiNNer chạy được trên macOS | Dùng để so A/B, nội suy model, xuất ONNX. **spandrel (MIT)** tự nhận diện arch và nạp state_dict, nên dùng trong script export Core ML |

**Cách vá traiNNer-redux cho MPS** [ước tính, chưa chạy thử]: đổi device thành `torch.device("mps")`; `use_amp: false` (huấn luyện fp32 trên MPS cho ổn định); `use_compile: false`; `prefetch_mode: ~`; `num_gpu: 0` kết hợp patch device; tắt `fliploss` và `perceptualanimeloss`; đặt `PYTORCH_ENABLE_MPS_FALLBACK=1` để op thiếu tự rơi về CPU (chậm, cần theo dõi log). Trên macOS, DataLoader dùng `spawn`, nên đặt `num_worker_per_gpu` khoảng 4–8 và đọc ảnh đã crop sẵn. Pipeline OTF dùng DiffJPEG và filter2D trên GPU, có thể chậm hoặc lỗi trên MPS. **Khuyến nghị tạo LR offline (paired) bằng script CPU dùng libjpeg/libwebp thật**: vừa thực tế hơn, vừa tránh được rủi ro MPS.

---

## 3. Công thức xử lý từng vấn đề

### 3.1 Sắc giả, "painterly", ảo giác chi tiết
1. **Tắt USM trên GT** (BasicSR: `l1_gt_usm/percep_gt_usm/gan_gt_usm: false`; traiNNer: `lq_usm: false`). Đây là nguồn gốc trực tiếp của halo và cảm giác "sắc giả".
2. **Huấn luyện hai pha:** fidelity trước (Charbonnier hoặc MS-SSIM+L1, không GAN), sau đó GAN nhẹ. traiNNer khuyến nghị luôn dùng pretrain fidelity cho model perceptual [đã kiểm, training_guidelines.md].
3. **Tỉ lệ loss gợi ý cho pha GAN** (theo thang của traiNNer): `mssim 0.5–1.0`, `charbonnier/L1 1.0`, `perceptual 0.01` (thang traiNNer; tương đương ~0.5–1.0 ở BasicSR), `dists 0.25–0.3`, `ldl 1.0`, `hsluv 1.0`, **`gan 0.02–0.05`** (template mặc định là 0.1). Nếu dùng VGG thì giảm trọng số `conv5_4`: lớp sâu là thủ phạm gây vân "sơn dầu".
4. **LDL** (Liang và cs., CVPR 2022, [repo](https://github.com/csjliang/LDL), Apache-2.0) phạt các vùng artifact GAN dựa trên phương sai cục bộ của residual, đồng thời dùng EMA của G. Đã có sẵn trong traiNNer (`ldlloss`).
5. **Nội suy mạng** (ESRGAN/Real-ESRGAN): `θ = α·θ_GAN + (1−α)·θ_fidelity` với α ≈ 0.5–0.8. Cách này hợp với thanh "Detail/Realism" của Pixora. Có thể xuất 2–3 mức α thành các `.mlpackage` riêng, hoặc blend output (rẻ hơn nhưng kém hơn nội suy trọng số).
6. Dùng **EMA** (`ema_decay 0.999`) và chọn checkpoint bằng mắt trên tập val *thật*. GAN dễ sụp nếu chạy quá lâu.

### 3.2 Giữ chữ (keycap, nhãn, tem thông số)
Cách thực tế, xếp theo chi phí từ thấp đến cao:
1. **Dữ liệu:** 20–30% patch có chữ, gồm crop cận bàn phím, sticker Intel/AMD, nhãn đáy máy, cổng I/O có ký hiệu. Có thể sinh thêm crop chữ tổng hợp (nhiều font, cỡ 6–20 px ở LR) theo cách của 2xBSTexty (model GPL, chỉ học ý tưởng).
2. **Tránh degradation phá chữ trong dữ liệu train:** noise và blur quá mạnh khiến mô hình học cách "đoán" nét chữ. Dùng blur σ ≤ 1.5 cho phần lớn mẫu.
3. **Mặt nạ chữ offline:** chạy Apple Vision (`VNRecognizeTextRequest`) trên HR để lấy bbox chữ, lưu thành mask. Khi train, nhân **pixel loss ×3–5** trong mask và **tắt GAN loss trong mask** (GAN masked). Cần vài chục dòng code custom loss trong traiNNer [ước tính].
4. **Loss gradient/biên:** `sobeledgeloss` (có sẵn) hoặc gradient-profile loss (dùng trong TSRN/TextZoom) với trọng số 0.1–0.5.
5. (Về sau) **loss nhận dạng chữ:** dùng recognizer đông cứng để tạo attention theo nét (Text Gestalt, AAAI 2022, [paper](https://ojs.aaai.org/index.php/AAAI/article/view/19904), code trong FudanVI/FudanOCR, chưa rõ license). Không tốn thêm thời gian inference, nhưng tích hợp phức tạp. Chỉ nên làm khi bước 1–4 chưa đủ.

### 3.3 Da và texture tự nhiên, local contrast
- Ưu tiên **DISTS** (chịu được texture tự nhiên, ít "đắp" vân hơn VGG) hoặc LPIPS cho perceptual.
- **Không khử noise quá tay trong degradation:** nếu LR luôn nhiễu nặng, mô hình sẽ học cách làm mịn, sinh da nhựa. Dùng noise nhẹ (σ 0–8/255, poisson 0.05–1), hơn 50% mẫu không thêm noise.
- **Màu và tông:** `hsluvloss` cho màu; **LR-consistency loss** (downscale(SR) ≈ LR, ý tưởng "consistency" trong neosr) để giữ local contrast và độ sáng đúng với ảnh gốc, tránh tăng tương phản giả [cần code custom, đơn giản].
- **Mặt người:** GFPGAN/CodeFormer chính là nguồn gây "da nhựa". Hãy để mô hình SR chung xử lý mặt, chỉ bật face restore khi mặt rất nhỏ, và blend với fidelity khoảng 0.5. Cũng có thể thêm 5–10% crop chân dung vào dataset.
- Có thể thêm tùy chọn **grain nhẹ** (film grain) sau SR để có cảm giác "chụp thật" [ước tính].

### 3.4 Chuẩn bị dataset
- **Chất lượng HR:** dùng ảnh gốc từ máy ảnh (JPEG q ≥ 95 hoặc xuất từ RAW), cạnh ≥ 2000 px. Downscale HR ×0.5–0.75 (lanczos/area) để GT sạch noise và JPEG. **Không dùng ảnh đã đăng web làm GT.**
- **Số lượng:** 500–2.000 ảnh của chủ site → crop **512×512, step 256** → khoảng 10k–40k tile. Lọc tile phẳng (tường, nền trắng) bằng phương sai Laplacian. Trộn **30–50% ảnh tổng quát** (ví dụ LSDIR, DIV2K/Flickr2K; cần kiểm license) để tránh catastrophic forgetting.
- **Degradation mô phỏng ảnh sản phẩm trên web:** resize bằng bicubic/lanczos/area/bilinear (scale ngẫu nhiên quanh 1/4); blur σ 0.2–1.5 (xác suất 0.5); noise nhẹ như trên; **JPEG hai tầng q 50–95** và **WebP q 60–90** (xác suất 0.3); sinc/ringing xác suất 0.1. Nên sinh 2–4 bản LR khác nhau cho mỗi HR.
- **Val:** 20–50 ảnh web thật (chính loại ảnh người dùng sẽ upscale) để so bằng mắt, cộng 20 cặp paired để theo dõi PSNR/SSIM/DISTS.
- Kích thước patch: `lq_size 64` (GT 256) khi bắt đầu, sau tăng lên 96 (GT 384) nếu RAM/thời gian cho phép. Bật flip/rot, nhưng **tắt rot90 với patch có chữ** nếu muốn mô hình học riêng chữ theo hướng ngang.

---

## 4. Diffusion SR, hướng cho chế độ kiểu "Recovery" về sau

| Phương pháp | Bước | Nền tảng | License | Ghi chú cho Mac |
|---|---|---|---|---|
| StableSR ([repo](https://github.com/IceClear/StableSR)) | ~200 bước | SD 2.1 | **S-Lab 1.0, phi thương mại** | Quá chậm |
| SUPIR ([repo](https://github.com/Fanghua-Yu/SUPIR)) | ~50 bước | SDXL + LLaVA | **License riêng của SupPixel, hạn chế thương mại** | Rất nặng (>20 GB), không thực tế |
| SeeSR ([repo](https://github.com/cswry/SeeSR)) | ~50 bước | SD 2 + RAM | Apache-2.0 (code); trọng số SD theo OpenRAIL++ | Chậm |
| **OSEDiff** ([repo](https://github.com/cswry/OSEDiff)) | **1 bước** | SD 2.1 + LoRA | Apache-2.0 (code) + OpenRAIL++ (SD) | Ứng viên khả thi nhất. Theo paper, tile 512 tốn khoảng 0.1 s trên A100; trên M2 Ultra có lẽ vài giây mỗi tile [ước tính]. Vẫn có ảo giác, kể cả với chữ |
| InvSR ([repo](https://github.com/zsyOAOA/InvSR)) | 1–5 bước | SD-Turbo | **S-Lab, phi thương mại** | – |
| SinSR / ResShift | 1 bước | – | Chưa rõ (ResShift theo S-Lab NC) | Đã có bản Core ML cộng đồng trên HF (mlboydaisuke/SinSR-CoreML), có thể dùng làm tham khảo kỹ thuật |
| SeedVR2 ([repo](https://github.com/Iceclear/SeedVR2)) | 1 bước | DiT 3B/7B | Apache-2.0 | Quá nặng cho Core ML |

Kết luận: nếu cần chế độ "Recovery", OSEDiff (Apache + OpenRAIL) là lựa chọn đáng thử, nhưng **chỉ nên làm sau** khi bản GAN fine-tune đã ổn. Diffusion luôn có rủi ro làm sai chữ trên keycap, và điều này ngược với yêu cầu chính của sản phẩm.

---

## 5. Kế hoạch đề xuất cho Pixora

**Kiến trúc:** RealPLKSR, `dim 64, n_blocks 28, kernel 17, layer_norm: true, upsampler: pixelshuffle`, scale 4. Bản 2x có thể train sau từ `2x_realplksr_mssim_pretrain` (CC0).

**Checkpoint khởi đầu:**
- Phương án A (nhanh có kết quả): `4xNomosWebPhoto_RealPLKSR` (CC-BY-4.0). Trước khi dùng, kiểm tra key trong state_dict: có `feats.N.layer_norm.weight` là LN, có `feats.N.norm.weight` là GroupNorm. Nếu là GroupNorm thì phải dùng `layer_norm: false` và **tile lớn (512) với overlap 32 px**, sau đó kiểm tra kỹ seam.
- Phương án B (sạch license, tile-safe): pretrain fidelity của riêng mình ở pha 1, xuất phát từ `4x_realplksr_mssim_pretrain` (CC0), hoặc từ `4xmssim_realplksr_dysample_pretrain` với `strict_load_g: false`. Hai bản chỉ khác nhau ở `to_img`; phần `feats` nạp được bình thường [suy luận từ code].

**Các bước:**
1. Gom 1.000–2.000 ảnh gốc → downscale ×0.5–0.75 → crop 512/256 → lọc tile phẳng → tạo mask chữ bằng Vision.
2. Sinh LR offline: 3 bản mỗi HR với pipeline ở mục 3.4, tỉ lệ 1/4.
3. Vá traiNNer-redux cho MPS (mục 2), chạy thử 200 iter để đo s/iter.
4. **Pha 1, fidelity:** 20k–40k iter, Charbonnier + MS-SSIM, lr 1e-4.
5. **Pha 2, GAN nhẹ:** 20k–40k iter theo YAML bên dưới.
6. Nội suy pha 1 với pha 2 ở α = 0.3 / 0.6 / 0.85, so A/B trên tập val web thật với Real-ESRGAN.
7. Export Core ML.

**Sketch config pha 2 (traiNNer-redux):**
```yaml
name: 4x_pixora_realplksr_laptop_gan
scale: 4
use_amp: false            # MPS: train fp32
use_compile: false
num_gpu: 0                # + patch device -> mps
high_order_degradation: false   # LR sinh offline (paired)
datasets:
  train:
    type: pairedimagedataset
    dataroot_gt: [datasets/laptop/hr, datasets/general/hr]
    dataroot_lq: [datasets/laptop/lr, datasets/general/lr]
    lq_size: 64           # GT 256
    use_hflip: true
    use_rot: false
    num_worker_per_gpu: 6
    batch_size_per_gpu: 8
    accum_iter: 2         # batch hiệu dụng 16
    prefetch_mode: ~
network_g: {type: realplksr, upsampler: pixelshuffle, layer_norm: true}
network_d: {type: dunet}
path:
  pretrain_network_g: experiments/pixora_phase1_fidelity/models/net_g_ema_latest.safetensors
  strict_load_g: true
train:
  ema_decay: 0.999
  optim_g: {type: AdamW, lr: !!float 5e-5, betas: [0.9, 0.99]}
  optim_d: {type: AdamW, lr: !!float 5e-5, betas: [0.9, 0.99]}
  scheduler: {type: MultiStepLR, milestones: [20000], gamma: 0.5}
  total_iter: 40000
  losses:
    - {type: charbonnierloss, loss_weight: 1.0}
    - {type: mssimloss, loss_weight: 0.5}
    - {type: distsloss, loss_weight: 0.25}
    - {type: perceptualloss, criterion: charbonnier, loss_weight: 0.005}
    - {type: ldlloss, loss_weight: 1.0}
    - {type: hsluvloss, criterion: charbonnier, loss_weight: 1.0}
    - {type: sobeledgeloss, loss_weight: 0.2}
    - {type: ganloss, gan_type: vanilla, loss_weight: 0.03}
val:
  val_enabled: true
  val_freq: 2000
logger: {save_checkpoint_freq: 2000, save_checkpoint_format: safetensors}
```
(Loss có mask chữ và LR-consistency là code custom thêm vào traiNNer, chưa có trong config gốc.)

**Ước tính compute trên M2 Ultra (76-core GPU, ~27 TFLOPS fp32)** [ước tính, cần đo]:
- G RealPLKSR khoảng 15 MFLOP mỗi pixel LR. Một batch 8×64² cộng VGG/DISTS và U-Net discriminator ở 256² tốn khoảng 2–3 TFLOP mỗi iter. Với hiệu suất MPS 20–40%, mỗi iter mất **khoảng 0.3–1 s**.
- Pha 1 (30k iter): khoảng 3–8 giờ. Pha 2 (40k iter): khoảng 4–11 giờ, chưa tính phần OTF vì đã làm offline. SPAN nhanh hơn khoảng 3–5 lần.
- Bộ nhớ: dư sức với unified memory. Nút cổ chai sẽ là băng thông MPS và các op fallback về CPU.

**Inference Core ML** [ước tính]: RealPLKSR trên GPU Apple có thể khoảng 0.5–1.5 s cho tile LR 256² ra 1024². Ảnh 3000×2000 (khoảng 100 tile kể cả overlap) mất khoảng 1–2 phút, vẫn nhanh hơn RRDBNet hiện tại. SPAN nhanh hơn khoảng 5–8 lần. Nên dùng `computeUnits = .all` và đo riêng ANE: conv 17×17 có thể không chạy trên ANE mà rơi về GPU.

**Export Core ML:**
```python
import torch, coremltools as ct
from spandrel import ModelLoader            # MIT

m = ModelLoader().load_from_file("net_g_ema.safetensors").model.eval()
# vá PLKConv2d.forward: split -> conv -> cat (tránh gán in-place khi eval)
for mod in m.modules():
    if mod.__class__.__name__ == "PLKConv2d":
        def fwd(x, self=mod):
            a, b = torch.split(x, [self.idx, x.size(1) - self.idx], 1)
            return torch.cat([self.conv(a), b], 1)
        mod.forward = fwd

ex = torch.rand(1, 3, 256, 256)
ts = torch.jit.trace(m, ex)
ml = ct.convert(
    ts, convert_to="mlprogram",
    inputs=[ct.TensorType(name="input", shape=ex.shape)],
    outputs=[ct.TensorType(name="output")],
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS14,
)
ml.save("Pixora_RealPLKSR_4x_256.mlpackage")
```
Kiểm tra sau khi export: so PyTorch fp32 với Core ML fp16 trên 20 tile, PSNR nên > 45 dB và không có NaN. Nếu LayerNorm tràn fp16, giữ riêng op này ở fp32 qua `ct.transform.FP16ComputePrecision(op_selector=...)`. Ngoài tile cố định 256, có thể dùng `EnumeratedShapes` (256 và 512) để giảm số tile. Overlap nên 16–32 px, blend bằng cửa sổ cosine.

---

## Nguồn chính
- traiNNer-redux: https://github.com/the-database/traiNNer-redux (Apache-2.0); benchmark: `docs/source/benchmarks.md`; template: `options/_templates/train/RealPLKSR/*.yml`
- neosr: https://github.com/neosr-project/neosr (Apache-2.0)
- Real-ESRGAN Training.md và `options/finetune_realesrgan_x4plus.yml`: https://github.com/xinntao/Real-ESRGAN (BSD-3); BasicSR (Apache-2.0)
- PLKSR paper: https://arxiv.org/abs/2404.11848; code https://github.com/dslisleedh/PLKSR (MIT)
- SPAN: https://github.com/hongyuanyu/SPAN (Apache-2.0); MoSR: https://github.com/umzi2/MoSR (MIT)
- OpenModelDB data: https://github.com/OpenModelDB/open-model-database (`data/models/*.json`); bản phát hành của Phhofm: https://github.com/Phhofm/models
- LDL: https://github.com/csjliang/LDL (Apache-2.0)
- Text Gestalt: https://ojs.aaai.org/index.php/AAAI/article/view/19904
- spandrel: https://github.com/chaiNNer-org/spandrel (MIT); chaiNNer (GPL-3.0)
- Diffusion: StableSR (S-Lab NC), SUPIR (license SupPixel), SeeSR/OSEDiff (Apache-2.0), InvSR (S-Lab NC), SeedVR2 (Apache-2.0)
- CodeFormer: https://github.com/sczhou/CodeFormer (S-Lab NC)
