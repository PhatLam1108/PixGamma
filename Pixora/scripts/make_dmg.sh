#!/bin/bash
# Builds the installer for a GitHub release.
#   scripts/make_dmg.sh            → build/Pixora-<version>.dmg (+ .sha256 for the in-app updater)
#   scripts/make_dmg.sh --recover  → also build/Pixora-Recover-<version>-{1,2}.zip
#
# The DMG holds Pixora.app (CLI and all upscaling models inside), an Applications link, a
# double-click CLI installer and a short guide. Recover (SD 1.5 + ControlNet Tile, ~2.7 GB)
# is too big for one release file (2 GB limit), so it ships as two zips that unpack into the
# same folder; "Cài model Recover.command" in the DMG installs them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$ROOT/Sources/PixoraCore/APIServer.swift")"
OUT="$ROOT/build"
DMG="$OUT/Pixora-$VERSION.dmg"
# Assembled outside iCloud-synced folders (Finder xattrs break codesign and hdiutil).
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

"$ROOT/scripts/build.sh"

echo "▸ Chuẩn bị DMG $VERSION"
VOL="$STAGE/Pixora"
mkdir -p "$VOL"
ditto "$OUT/Pixora.app" "$VOL/Pixora.app"
ln -s /Applications "$VOL/Applications"
cp "$ROOT/Models/LICENSES.md" "$VOL/Giấy phép model.md"

cat > "$VOL/Cài lệnh pixora (CLI).command" <<'SH'
#!/bin/bash
# Links the `pixora` command-line tool from /Applications/Pixora.app into your PATH.
APP_CLI="/Applications/Pixora.app/Contents/Helpers/pixora"
if [ ! -x "$APP_CLI" ]; then
  echo "Chưa thấy Pixora trong /Applications. Hãy kéo Pixora.app vào Applications trước."
  read -n 1 -s -r -p "Nhấn phím bất kỳ để đóng."; exit 1
fi
for dir in /opt/homebrew/bin /usr/local/bin; do
  if [ -d "$dir" ] && [ -w "$dir" ]; then
    ln -sf "$APP_CLI" "$dir/pixora"
    echo "Đã cài: $dir/pixora"; "$dir/pixora" --version
    read -n 1 -s -r -p "Xong. Nhấn phím bất kỳ để đóng."; exit 0
  fi
done
mkdir -p "$HOME/.local/bin"
ln -sf "$APP_CLI" "$HOME/.local/bin/pixora"
echo "Đã cài: $HOME/.local/bin/pixora"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *)
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
  echo "Đã thêm ~/.local/bin vào PATH trong ~/.zshrc (mở Terminal mới để dùng)." ;;
esac
read -n 1 -s -r -p "Xong. Nhấn phím bất kỳ để đóng."
SH

cat > "$VOL/Cài model Recover.command" <<'SH'
#!/bin/bash
# Installs the Recover (diffusion) models from the two release zips into
# ~/Library/Application Support/Pixora/Models/Recover.
DEST="$HOME/Library/Application Support/Pixora/Models"
cd "$HOME/Downloads" 2>/dev/null || cd "$HOME"
shopt -s nullglob
ZIPS=(Pixora-Recover-*-1.zip Pixora-Recover-*-2.zip)
if [ ${#ZIPS[@]} -lt 2 ]; then
  echo "Cần tải 2 file Pixora-Recover-…-1.zip và …-2.zip từ trang Releases vào thư mục Downloads."
  read -n 1 -s -r -p "Nhấn phím bất kỳ để đóng."; exit 1
fi
mkdir -p "$DEST"
rm -rf "$DEST/Recover"
for z in "${ZIPS[@]}"; do echo "Giải nén $z…"; ditto -x -k "$z" "$DEST"; done
echo "Đã cài model Recover vào: $DEST/Recover"
read -n 1 -s -r -p "Xong. Mở lại Pixora để dùng chế độ Recover. Nhấn phím bất kỳ để đóng."
SH
chmod +x "$VOL"/*.command

cat > "$VOL/Đọc trước.txt" <<TXT
Pixora $VERSION — phóng to và phục hồi ảnh bằng AI, chạy hoàn toàn trên máy (Apple Silicon).

CÀI ĐẶT
1. Kéo Pixora.app vào thư mục Applications.
2. Lần đầu mở: chuột phải vào Pixora trong Applications → Open → Open.
   (App ký ad-hoc, chưa qua notarize của Apple nên macOS hỏi xác nhận một lần.)
   Nếu macOS báo "bị hỏng": mở Terminal và chạy
       xattr -dr com.apple.quarantine /Applications/Pixora.app
3. Muốn dùng lệnh pixora trong Terminal: bấm đúp "Cài lệnh pixora (CLI).command".

TỰ CẬP NHẬT
Menu Pixora → Kiểm tra cập nhật… Lần đầu cần một token GitHub chỉ đọc (Fine-grained token,
chỉ repo Pixora, quyền Contents: Read-only); app cất token trong Keychain và từ đó tự kiểm tra
mỗi ngày, tải bản mới, kiểm tra SHA-256 rồi tự cài.

CHẾ ĐỘ RECOVER (tái tạo chi tiết bằng diffusion, tùy chọn)
Model Recover nặng ~2,7 GB nên tách riêng. Tải Pixora-Recover-$VERSION-1.zip và -2.zip
ở trang Releases vào Downloads, rồi bấm đúp "Cài model Recover.command".

YÊU CẦU
macOS 14 trở lên, chip Apple Silicon (M1 trở lên). Recover nên có từ 32 GB RAM.

GỠ CÀI ĐẶT
Xóa /Applications/Pixora.app, ~/Library/Application Support/Pixora và (nếu đã cài CLI)
file pixora trong /opt/homebrew/bin, /usr/local/bin hoặc ~/.local/bin.

Giấy phép model: xem "Giấy phép model.md". CodeFormer chỉ dùng phi thương mại.
TXT

echo "▸ Tạo $DMG"
rm -f "$DMG"
hdiutil create -volname "Pixora $VERSION" -srcfolder "$VOL" -fs HFS+ -format ULFO -ov "$STAGE/Pixora.dmg" >/dev/null
mv "$STAGE/Pixora.dmg" "$DMG"
hdiutil verify "$DMG" >/dev/null && echo "  ✓ $(du -h "$DMG" | cut -f1)  $DMG"
# Checksum for the in-app updater (it refuses a download without a matching .sha256).
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "  ✓ $DMG.sha256"

if [ "${1:-}" = "--recover" ]; then
  REC="$(cd "$ROOT/Models/Recover" && pwd -P)"
  echo "▸ Đóng gói model Recover"
  mkdir -p "$STAGE/r1/Recover" "$STAGE/r2/Recover"
  ln -s "$REC/ControlledUnet.mlmodelc" "$STAGE/r1/Recover/ControlledUnet.mlmodelc"
  for f in "$REC"/*; do
    [ "$(basename "$f")" = "ControlledUnet.mlmodelc" ] || ln -s "$f" "$STAGE/r2/Recover/$(basename "$f")"
  done
  for n in 1 2; do
    Z="$OUT/Pixora-Recover-$VERSION-$n.zip"
    rm -f "$Z"
    (cd "$STAGE/r$n" && zip -qr -0 "$Z" Recover)   # weights do not compress; store only
    echo "  ✓ $(du -h "$Z" | cut -f1)  $Z"
  done
fi
echo "✓ Xong"
