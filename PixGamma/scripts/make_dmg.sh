#!/bin/bash
# Builds the installer for a GitHub release.
#   scripts/make_dmg.sh            → build/PixGamma-<version>.dmg (+ .sha256 for the in-app updater)
#   scripts/make_dmg.sh --recover  → also build/PixGamma-Recover-<version>-{1,2}.zip
#
# Pixora was the name up to 0.2.1, and its updater only takes a Pixora-<version>.dmg holding
# Pixora.app. So the same app is also packed as build/Pixora-<version>.dmg (+ .sha256); upload
# both while 0.2.1 installs are around. The new updater moves Pixora.app to PixGamma.app.
#
# The DMG holds PixGamma.app (CLI and all upscaling models inside), an Applications link, a
# double-click CLI installer and a short guide. Recover (SD 1.5 + ControlNet Tile, ~2.7 GB)
# is too big for one release file (2 GB limit), so it ships as two zips that unpack into the
# same folder; "Cài model Recover.command" in the DMG installs them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$ROOT/Sources/PixGammaCore/APIServer.swift")"
OUT="$ROOT/build"
DMG="$OUT/PixGamma-$VERSION.dmg"
# Assembled outside iCloud-synced folders (Finder xattrs break codesign and hdiutil).
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

"$ROOT/scripts/build.sh"

echo "▸ Chuẩn bị DMG $VERSION"
VOL="$STAGE/PixGamma"
mkdir -p "$VOL"
ditto "$OUT/PixGamma.app" "$VOL/PixGamma.app"
ln -s /Applications "$VOL/Applications"
cp "$ROOT/Models/LICENSES.md" "$VOL/Giấy phép model.md"

cat > "$VOL/Cài lệnh pixgamma (CLI).command" <<'SH'
#!/bin/bash
# Links the `pixgamma` command-line tool from /Applications/PixGamma.app into your PATH.
APP_CLI="/Applications/PixGamma.app/Contents/Helpers/pixgamma"
if [ ! -x "$APP_CLI" ]; then
  echo "Chưa thấy PixGamma trong /Applications. Hãy kéo PixGamma.app vào Applications trước."
  read -n 1 -s -r -p "Nhấn phím bất kỳ để đóng."; exit 1
fi
for dir in /opt/homebrew/bin /usr/local/bin; do
  if [ -d "$dir" ] && [ -w "$dir" ]; then
    ln -sf "$APP_CLI" "$dir/pixgamma"
    ln -sf "$APP_CLI" "$dir/pixora"   # tên cũ, giữ cho script cũ
    echo "Đã cài: $dir/pixgamma"; "$dir/pixgamma" --version
    read -n 1 -s -r -p "Xong. Nhấn phím bất kỳ để đóng."; exit 0
  fi
done
mkdir -p "$HOME/.local/bin"
ln -sf "$APP_CLI" "$HOME/.local/bin/pixgamma"
ln -sf "$APP_CLI" "$HOME/.local/bin/pixora"
echo "Đã cài: $HOME/.local/bin/pixgamma"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *)
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
  echo "Đã thêm ~/.local/bin vào PATH trong ~/.zshrc (mở Terminal mới để dùng)." ;;
esac
read -n 1 -s -r -p "Xong. Nhấn phím bất kỳ để đóng."
SH

cat > "$VOL/Cài model Recover.command" <<'SH'
#!/bin/bash
# Installs the Recover (diffusion) models from the two release zips into
# ~/Library/Application Support/PixGamma/Models/Recover.
SUPPORT="$HOME/Library/Application Support"
# Pixora (0.2.1 and earlier) kept its models in Application Support/Pixora.
[ -d "$SUPPORT/Pixora" ] && [ ! -e "$SUPPORT/PixGamma" ] && mv "$SUPPORT/Pixora" "$SUPPORT/PixGamma"
DEST="$SUPPORT/PixGamma/Models"
cd "$HOME/Downloads" 2>/dev/null || cd "$HOME"
shopt -s nullglob
ZIPS=(PixGamma-Recover-*-1.zip PixGamma-Recover-*-2.zip)
[ ${#ZIPS[@]} -lt 2 ] && ZIPS=(Pixora-Recover-*-1.zip Pixora-Recover-*-2.zip)
if [ ${#ZIPS[@]} -lt 2 ]; then
  echo "Cần tải 2 file PixGamma-Recover-…-1.zip và …-2.zip từ trang Releases vào thư mục Downloads."
  read -n 1 -s -r -p "Nhấn phím bất kỳ để đóng."; exit 1
fi
mkdir -p "$DEST"
rm -rf "$DEST/Recover"
for z in "${ZIPS[@]}"; do echo "Giải nén $z…"; ditto -x -k "$z" "$DEST"; done
echo "Đã cài model Recover vào: $DEST/Recover"
read -n 1 -s -r -p "Xong. Mở lại PixGamma để dùng chế độ Recover. Nhấn phím bất kỳ để đóng."
SH
chmod +x "$VOL"/*.command

cat > "$VOL/Đọc trước.txt" <<TXT
PixGamma $VERSION — phóng to và phục hồi ảnh bằng AI, chạy hoàn toàn trên máy (Apple Silicon).

CÀI ĐẶT
1. Kéo PixGamma.app vào thư mục Applications.
2. Lần đầu mở: chuột phải vào PixGamma trong Applications → Open → Open.
   (App ký ad-hoc, chưa qua notarize của Apple nên macOS hỏi xác nhận một lần.)
   Nếu macOS báo "bị hỏng": mở Terminal và chạy
       xattr -dr com.apple.quarantine /Applications/PixGamma.app
3. Muốn dùng lệnh pixgamma trong Terminal: bấm đúp "Cài lệnh pixgamma (CLI).command".

TỰ CẬP NHẬT
Menu PixGamma → Kiểm tra cập nhật… App tự kiểm tra mỗi ngày, tải bản mới, kiểm tra SHA-256
rồi tự cài. Repo công khai nên không cần token GitHub.

ĐỔI TÊN
PixGamma là tên mới của Pixora (đến bản 0.2.1). Nếu máy còn /Applications/Pixora.app thì xóa
bản đó sau khi cài PixGamma. Lệnh cũ pixora vẫn chạy, là tên khác của pixgamma.

CHẾ ĐỘ RECOVER (tái tạo chi tiết bằng diffusion, tùy chọn)
Model Recover nặng ~2,7 GB nên tách riêng. Tải PixGamma-Recover-$VERSION-1.zip và -2.zip
ở trang Releases vào Downloads, rồi bấm đúp "Cài model Recover.command".

YÊU CẦU
macOS 14 trở lên, chip Apple Silicon (M1 trở lên). Recover nên có từ 32 GB RAM.

GỠ CÀI ĐẶT
Xóa /Applications/PixGamma.app, ~/Library/Application Support/PixGamma và (nếu đã cài CLI)
file pixgamma trong /opt/homebrew/bin, /usr/local/bin hoặc ~/.local/bin.

Giấy phép model: xem "Giấy phép model.md". CodeFormer chỉ dùng phi thương mại.
TXT

echo "▸ Tạo $DMG"
rm -f "$DMG"
hdiutil create -volname "PixGamma $VERSION" -srcfolder "$VOL" -fs HFS+ -format ULFO -ov "$STAGE/PixGamma.dmg" >/dev/null
mv "$STAGE/PixGamma.dmg" "$DMG"
hdiutil verify "$DMG" >/dev/null && echo "  ✓ $(du -h "$DMG" | cut -f1)  $DMG"
# Checksum for the in-app updater (it refuses a download without a matching .sha256).
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "  ✓ $DMG.sha256"

LEGACY="$OUT/Pixora-$VERSION.dmg"
echo "▸ Tạo $LEGACY (cho bản 0.2.1 trở về trước tự cập nhật)"
LVOL="$STAGE/Pixora"
mkdir -p "$LVOL"
ditto "$VOL/PixGamma.app" "$LVOL/Pixora.app"
ln -s /Applications "$LVOL/Applications"
rm -f "$LEGACY"
hdiutil create -volname "PixGamma $VERSION" -srcfolder "$LVOL" -fs HFS+ -format ULFO -ov "$STAGE/legacy.dmg" >/dev/null
mv "$STAGE/legacy.dmg" "$LEGACY"
(cd "$OUT" && shasum -a 256 "$(basename "$LEGACY")" > "$(basename "$LEGACY").sha256")
echo "  ✓ $(du -h "$LEGACY" | cut -f1)  $LEGACY"

if [ "${1:-}" = "--recover" ]; then
  REC="$(cd "$ROOT/Models/Recover" && pwd -P)"
  echo "▸ Đóng gói model Recover"
  mkdir -p "$STAGE/r1/Recover" "$STAGE/r2/Recover"
  ln -s "$REC/ControlledUnet.mlmodelc" "$STAGE/r1/Recover/ControlledUnet.mlmodelc"
  for f in "$REC"/*; do
    [ "$(basename "$f")" = "ControlledUnet.mlmodelc" ] || ln -s "$f" "$STAGE/r2/Recover/$(basename "$f")"
  done
  for n in 1 2; do
    Z="$OUT/PixGamma-Recover-$VERSION-$n.zip"
    rm -f "$Z"
    (cd "$STAGE/r$n" && zip -qr -0 "$Z" Recover)   # weights do not compress; store only
    echo "  ✓ $(du -h "$Z" | cut -f1)  $Z"
  done
fi
echo "✓ Xong"
