# Auto Monitor Switch (OBS)

An OBS Studio Lua script that **automatically shows the capture source for
whichever screen the focused window is on**, and hides the others.

On multi-monitor setups, you no longer need to switch sources by hand while
recording or streaming: when you move from your browser to your IDE, the
capture follows you.

---

## Why this project?

This was originally handled by a Python script running outside OBS:
`pywin32` found which monitor the active window was on, and
`obs-websocket` was used to connect to OBS and toggle source visibility.
It worked, but had three clear problems:

1. **Required an external process.** A Python install, the `pywin32` and
   `obsws-python` packages, a separate terminal window; the script had to be
   started by hand every time OBS was opened.
2. **WebSocket dependency.** You had to enable OBS's WebSocket server and
   hardcode the IP, port, and password into the script. If the network
   changed or the password was reset, the script went silent.
3. **Everything was hardcoded.** The scene name (`"Scene 5"`), source names
   (`"Monitor1"`, `"Monitor2"`), and monitor indexes (`0`, `1`) were written
   directly into the file. Renaming a scene or source, or changing monitor
   order, made the script activate the wrong source.

This version removes all three.

---

## How does it solve this?

**Runs inside OBS.** It uses OBS's built-in Lua (LuaJIT) scripting engine.
No Python, no pip packages, no WebSocket, no IP/port/password. The script
loads automatically whenever OBS opens.

**Scene name is automatic.** Visibility is always applied to whichever scene
is currently **live/recording** (`obs_frontend_get_current_scene`). In Studio
Mode, the program scene is used. When the scene changes, visibility is
reapplied to the new scene.

**Source names are automatic.** The script finds every screen capture source
in the scene itself (by source type, not by name). It works no matter what
the source is named, and only ever touches the sources it found itself — it
doesn't interfere with webcams, overlays, alerts, or other layers in the
scene. Groups are scanned too.

**Monitor matching is automatic.** No index guessing:

- **Windows / Linux:** The script reads which screen is selected in each
  capture source's settings, parses the `1920x1080 @ 0,0`-style label from
  OBS's own screen list, and gets the real screen rectangle. The focused
  window's position is compared against these rectangles. If scaling or
  rounding causes a mismatch, it falls back to the nearest screen.
- **macOS:** Instead of parsing text, identifiers are compared directly: the
  focused window's screen's `CGDirectDisplayID` / display UUID is matched
  against the value in the source's settings.

**Active-window detection is platform-specific, but dependency-free.** No
external tool is called (`xdotool`, `wmctrl`, `osascript`); system libraries
are used directly through LuaJIT's `ffi`: `user32` on Windows, `libX11` on
Linux, CoreGraphics on macOS.

---

## Which file should I use?

**Use the file for your own operating system.** Single-platform files are
simpler, load faster, and give platform-specific error messages.

| File | Platform | Required source type |
|---|---|---|
| `auto-monitor-switch-windows.lua` | Windows 10/11 | Display Capture |
| `auto-monitor-switch-linux.lua` | Linux (Xorg/X11) | Screen Capture (XSHM) |
| `auto-monitor-switch-macos.lua` | macOS (experimental) | Display / Screen Capture |
| `auto-monitor-switch-crossplatform.lua` | Windows **and** Linux | both |

The combined (cross-platform) file is for people who **move the same scene
collection between two machines**, or who'd rather keep a single file: it
detects the OS it's running on and uses the matching backend. If you don't
need that, prefer the single-platform file. (macOS is not included in the
combined file — use the separate one.)

Don't load more than one of these files at once — they'd all try to manage
the same sources and conflict with each other.

---

## Installation

1. Add **one screen capture source per monitor** to your scene. Names don't
   matter, call them whatever you like.
2. In OBS, go to **Tools → Scripts → "+"** and select the matching `.lua` file.
3. That's it. The script starts working as soon as it's loaded.

### Settings (in the Scripts window)

- **Enabled** — turn it off temporarily.
- **Poll interval (ms)** — 250 ms by default. Lowering it makes switching
  faster; the CPU cost is negligible.
- **Ignore focus on the OBS window** — stops the capture from jumping when you
  alt-tab into OBS itself (on by default).
- **Verbose logging** — writes what it finds to the Script Log.
- **Rescan sources** — press after adding/removing a monitor or changing a
  source's screen selection.

---

## Platform notes and limits

### Windows
No extra requirements. On setups with mixed DPI scaling, if coordinates don't
line up exactly it falls back to the nearest screen, so switching to the
wrong source is unlikely.

### Linux
- **Requires an Xorg (X11) session.** On Wayland, native windows aren't
  visible through `_NET_ACTIVE_WINDOW` (a compositor security restriction);
  only XWayland windows can be detected. The script warns if it detects
  Wayland.
- **Source type must be XSHM.** *Screen Capture (PipeWire)* sources don't
  report which screen they capture through the API (the choice is made in a
  portal dialog), so they can't be matched and are skipped.
- Xlib's default error handler terminates the process if a closing window is
  queried; the script temporarily silences it during its own calls and
  restores it afterward, so it won't crash OBS.

### macOS (experimental)
- Requires OBS to have **Screen Recording** permission (already needed for
  screen capture anyway).
- Only screen capture sources are managed; sources in *window* or
  *application* capture mode are left untouched.
- Since different OBS versions store the screen selection under different
  keys, the script tries all three (display UUID, display ID, screen index).
  If matching fails, the "Rescan sources" button logs the identifiers of both
  the sources and the currently focused screen — useful when reporting an issue.

---

## Troubleshooting

**Nothing switches at all.** Open the Script Log (the bottom tab of the
Scripts window) and press "Rescan sources". If it says "Sources found: 0",
your source type isn't supported (e.g. PipeWire on Linux, window capture on
macOS).

**It switches to the wrong screen.** Check the screen selection in each
source's OBS settings; two sources may be capturing the same screen. The
rectangles in the rescan output should match your actual monitor layout.

**Visibility breaks after switching scenes.** The script reapplies on scene
change; make sure the new scene also has one source per monitor.

**It switches when I click on the OBS window.** Turn on "Ignore focus on the
OBS window".

---

## Alternative

If you'd rather not maintain code, the **Advanced Scene Switcher** plugin can
set up similar behavior through a macro UI; however, configuring per-monitor
source visibility with it is more tedious, and you'd still need to select
source names by hand.

---
---

# Auto Monitor Switch (OBS) — Türkçe

OBS Studio için, **odaktaki pencere hangi ekrandaysa o ekranın yakalama kaynağını
otomatik gösteren**, diğerlerini gizleyen Lua scripti.

Çok monitörlü kurulumlarda kayıt/yayın yaparken elle kaynak açıp kapatmaya gerek
kalmaz: tarayıcıdan IDE'ye geçtiğinizde görüntü de sizinle birlikte geçer.

---

## Neden bu proje?

Bu iş başlangıçta OBS dışında çalışan bir Python scripti ile yapılıyordu:
`pywin32` ile aktif pencerenin monitörü bulunuyor, `obs-websocket` üzerinden
OBS'e bağlanılıp kaynak görünürlükleri değiştiriliyordu. Çalışıyordu, ama üç
belirgin sorunu vardı:

1. **Harici çalışma zorunluluğu.** Python kurulumu, `pywin32` ve `obsws-python`
   paketleri, ayrı bir terminal penceresi; OBS'i açınca scripti de elle
   başlatmak gerekiyordu.
2. **WebSocket bağımlılığı.** OBS'te WebSocket sunucusunu açmak, IP, port ve
   şifreyi scripte gömmek gerekiyordu. Ağ değişince veya şifre yenilenince
   script susuyordu.
3. **Her şeyin hardcode olması.** Sahne adı (`"Sahne 5"`), kaynak adları
   (`"Monitor1"`, `"Monitor2"`) ve monitör index'leri (`0`, `1`) dosyanın
   içine yazılmıştı. Sahne adı değişince, kaynak yeniden adlandırılınca veya
   monitör sırası değişince script yanlış kaynağı açıyordu.

Bu sürüm üçünü de ortadan kaldırıyor.

---

## Nasıl çözüyor?

**OBS'in içinde çalışıyor.** OBS'in yerleşik Lua (LuaJIT) script motorunu
kullanıyor. Python, pip paketi, WebSocket, IP/port/şifre yok. OBS açıldığında
script de otomatik yükleniyor.

**Sahne adı otomatik.** Görünürlük her zaman o an **yayında/kayıtta olan**
sahneye uygulanıyor (`obs_frontend_get_current_scene`). Studio Mode'da program
sahnesi esas alınır. Sahne değiştiğinde yeni sahnede görünürlük tekrar uygulanır.

**Kaynak adları otomatik.** Script sahnedeki tüm ekran yakalama kaynaklarını
kendisi buluyor (kaynak tipine göre, ada göre değil). Kaynağın adı ne olursa
olsun çalışır ve yalnızca kendi bulduğu kaynaklara dokunur; sahnedeki webcam,
overlay, alert gibi diğer katmanlara karışmaz. Gruplar da taranır.

**Monitör eşleştirmesi otomatik.** Index tahmini yok:

- **Windows / Linux:** Her yakalama kaynağının ayarından hangi ekranın seçili
  olduğu okunur, OBS'in kendi ekran listesindeki `1920x1080 @ 0,0` bilgisi
  ayrıştırılır ve gerçek ekran dikdörtgeni elde edilir. Odaktaki pencerenin
  konumu bu dikdörtgenlerle karşılaştırılır. Ölçekleme/yuvarlama farkı olursa
  en yakın ekrana düşülür.
- **macOS:** Metin ayrıştırmak yerine doğrudan kimlik karşılaştırılır; odaktaki
  pencerenin ekranının `CGDirectDisplayID` / display UUID değeri, kaynağın
  ayarındaki değerle eşlenir.

**Aktif pencere tespiti platforma özgü, ama bağımlılıksız.** Harici araç
(`xdotool`, `wmctrl`, `osascript`) çağrılmaz; sistem kütüphaneleri LuaJIT'in
`ffi`'si ile doğrudan kullanılır: Windows'ta `user32`, Linux'ta `libX11`,
macOS'ta CoreGraphics.

---

## Hangi dosyayı kullanmalıyım?

**Kendi işletim sisteminize ait dosyayı kullanın.** Tek platform dosyaları daha
sade, daha hızlı yüklenir ve hata mesajları o platforma özeldir.

| Dosya | Platform | Gereken kaynak tipi |
|---|---|---|
| `auto-monitor-switch-windows.lua` | Windows 10/11 | Display Capture |
| `auto-monitor-switch-linux.lua` | Linux (Xorg/X11) | Screen Capture (XSHM) |
| `auto-monitor-switch-macos.lua` | macOS (deneysel) | Display / Screen Capture |
| `auto-monitor-switch-crossplatform.lua` | Windows **ve** Linux | ikisi de |

Karma (cross-platform) dosya, **aynı sahne koleksiyonunu iki makine arasında
taşıyanlar** veya tek dosya bulundurmak isteyenler için hazırlandı: çalıştığı
işletim sistemini kendisi algılayıp ilgili arka ucu kullanır. İhtiyacınız yoksa
tek platform dosyasını tercih edin. (macOS karma dosyaya dahil değildir, ayrı
dosyayı kullanın.)

Aynı anda birden fazla dosyayı yüklemeyin — hepsi aynı kaynakları yönetmeye
çalışır ve birbirleriyle çakışır.

---

## Kurulum

1. Sahnenizde **her monitör için birer ekran yakalama kaynağı** ekleyin.
   Adları önemli değil, istediğinizi verebilirsiniz.
2. OBS'te **Tools / Araçlar → Scripts → "+"** ile ilgili `.lua` dosyasını seçin.
3. Bu kadar. Script yüklendiği anda çalışmaya başlar.

### Ayarlar (Scripts penceresinde)

- **Etkin** — geçici olarak kapatmak için.
- **Kontrol aralığı (ms)** — varsayılan 250 ms. Düşürmek tepkiyi hızlandırır,
  CPU maliyeti ihmal edilebilir düzeydedir.
- **OBS penceresine geçince değiştirme** — OBS'e alt-tab yaptığınızda görüntünün
  zıplamasını engeller (varsayılan açık).
- **Ayrıntılı log** — Script Log'a ne bulduğunu yazar.
- **Kaynakları yeniden tara** — monitör ekleyip çıkardıktan veya kaynakların
  ekran seçimini değiştirdikten sonra basın.

---

## Platform notları ve sınırlar

### Windows
Ek gereksinim yok. Farklı DPI ölçeklemeli monitörlerde koordinatlar birebir
tutmazsa en yakın ekrana düşülür, yanlış kaynağa geçme ihtimali düşüktür.

### Linux
- **Xorg (X11) oturumu gerekir.** Wayland'de native pencereler
  `_NET_ACTIVE_WINDOW` üzerinden görünmez (kompozitör güvenlik kısıtı); yalnızca
  XWayland pencereleri tespit edilebilir. Script Wayland algılarsa uyarı basar.
- **Kaynak tipi XSHM olmalı.** *Screen Capture (PipeWire)* kaynakları hangi
  ekranı yakaladığını API'ye bildirmez (seçim portal diyaloğunda yapılır), bu
  yüzden eşleştirilemez ve atlanır.
- Xlib'in varsayılan hata işleyicisi kapanmakta olan bir pencere sorgulandığında
  süreci sonlandırır; script kendi çağrıları sırasında bunu geçici olarak
  susturup sonra eski haline döndürür, yani OBS'i düşürmez.

### macOS (deneysel)
- OBS'in **Ekran Kaydı** iznine ihtiyaç duyar (ekran yakalama için zaten gerekli).
- Yalnızca ekran yakalama kaynakları yönetilir; *window* veya *application*
  yakalama modundaki kaynaklara dokunulmaz.
- OBS sürümleri ekran seçimini farklı anahtarlarda saklayabildiği için script
  üç yolu da dener (display UUID, display ID, ekran index'i). Eşleşme olmazsa
  "Kaynakları yeniden tara" düğmesi log'a kaynakların ve o anki ekranın
  kimliklerini yazar; sorun bildirirken bu çıktı işe yarar.

---

## Sorun giderme

**Hiç geçiş olmuyor.** Script Log'u açın (Scripts penceresinin alt sekmesi) ve
"Kaynakları yeniden tara" düğmesine basın. Log'da "Sources found: 0" yazıyorsa
kaynak tipiniz desteklenmiyor demektir (Linux'ta PipeWire, macOS'ta window
capture gibi).

**Yanlış ekrana geçiyor.** Kaynakların OBS ayarındaki ekran seçimini kontrol
edin; iki kaynak aynı ekranı yakalıyor olabilir. Yeniden tara çıktısındaki
dikdörtgenler gerçek monitör yerleşiminizle uyuşmalı.

**Sahne değişince görünürlük bozuluyor.** Script sahne değişiminde yeniden
uygular; yeni sahnede de her monitör için birer kaynak bulunduğundan emin olun.

**OBS penceresine tıklayınca değişiyor.** "OBS penceresine geçince değiştirme"
seçeneğini açın.

---

## Alternatif

Kod tutmak istemiyorsanız **Advanced Scene Switcher** eklentisi makro arayüzüyle
benzer senaryolar kurabilir; ancak monitör bazlı kaynak görünürlüğü için kurulumu
bundan daha zahmetlidir ve yine kaynak adlarını elle seçmeniz gerekir.

---

## Not on script UI text

The scripts' in-app settings panel (`script_description`, checkbox and slider
labels shown inside OBS's Scripts window) is still in Turkish, since only the
runtime log/warning messages were translated to English in this pass. Say so
if you'd like the UI panel translated too.
