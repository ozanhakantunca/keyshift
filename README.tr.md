<p align="center">
  <img src="Resources/AppIcon/Keyshift.png" width="128" alt="Keyshift simgesi">
</p>

<h1 align="center">Keyshift</h1>

<p align="center">
  Windows ve Linux kısayollarını Mac'e taşıyan ücretsiz, açık kaynaklı klavye eşleme aracı.
  <br>
  <a href="README.md">English</a> ·
  <a href="https://github.com/ozanhakantunca/keyshift/releases">İndir</a>
</p>

---

Keyshift, günlük klavye kısayolları için Karabiner-Elements'a hafif bir alternatif. Hazır bir
profil seçip başlayabilir, istediğiniz tuşları menü çubuğundan değiştirebilirsiniz.

## Özellikler

- **Klavye ve fare eşleme** için macOS'un olay yakalama arayüzünü (CGEventTap) kullanır. Çekirdek
  veya DriverKit uzantısı gerektirmez. Caps Lock ya da bir değiştirici tuş içeren, tek tuştan tek
  tuşa genel eşlemeler için macOS'un `hidutil` ile aynı klavye düzeyi eşleme mekanizmasını kullanır.
- **Türkçe ve İngilizce ayarlar** penceresinde profiller, kurallar, kısayol kaydedici, çakışma
  uyarıları ve olay görüntüleyici bulunur. Uyarılar hem kurallar arasındaki hem de macOS
  kısayollarıyla olan çakışmaları gösterir.
- **Uygulamaya göre kurallar** paket kimliği, uygulama grubu veya `/steamapps/common/` gibi bir
  dosya yolu parçasıyla sınırlandırılabilir. Kurallar, bir metin alanı odaktayken veya yalnızca
  metin alanı odağı yokken çalışacak şekilde de ayarlanabilir.
- **Windows, Linux ve Terminal profilleri** alıştığınız masaüstü ve terminal kısayollarını getirir.
- **Klavye düzenine uyum.** Tuş adları etkin klavye düzenini izler. Türkçe Q ve ABD dışındaki
  diğer düzenlerle de çalışır.
- **Karabiner'dan kural aktarma** ve kaydedildiğinde yeniden yüklenen **YAML ayar dosyası**.
- **Yerel çalışma.** Uygulama kendi başına ağ isteği göndermez, telemetri toplamaz.

macOS 13 Ventura veya daha yenisi gerekir. Sürüm paketi Apple silicon ve Intel Mac'ler için
evrensel bir çalıştırılabilir dosya içerir.

## Kurulum

### İndirerek (DMG)

1. [GitHub sürümlerinden](https://github.com/ozanhakantunca/keyshift/releases) `Keyshift-x.y.z.dmg`
   dosyasını indirin ve **Keyshift**'i **Uygulamalar** klasörüne sürükleyin. İndirdiğiniz dosyayı
   doğrulamak için `Keyshift-x.y.z.dmg.sha256` dosyasını da aynı klasöre indirip şunu çalıştırın:

   ```sh
   shasum -a 256 -c Keyshift-*.dmg.sha256
   ```
2. Uygulama kendinden imzalı bir sertifikayla imzalanmıştır. Apple'ın noter onayı bulunmadığı için
   ilk açılış engellenir. Uygulamayı bir kez açmayı deneyin, ardından
   **Sistem Ayarları → Gizlilik ve Güvenlik** bölümünden **Yine de Aç**'ı seçin.
   macOS 13 ve 14'te Finder'da uygulamaya sağ tıklayıp **Aç**'ı da seçebilirsiniz.
   [Apple'ın Gatekeeper açıklaması](https://support.apple.com/tr-tr/102445),
   [macOS 15'teki değişiklik](https://developer.apple.com/news/?id=saqachfa). Ya da şu komutu çalıştırın:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Keyshift.app
   ```

### Kaynaktan derleyerek

Swift 6 veya daha yenisini içeren Xcode Komut Satırı Araçları gerekir (`xcode-select --install`).

```sh
git clone https://github.com/ozanhakantunca/keyshift
cd keyshift
./scripts/create-signing-cert.sh   # bir kez çalıştırın, izinler sonraki derlemelerde korunsun
./scripts/install.sh --with-cli    # derler, kurar ve keyshift komutunu bağlar
```

`create-signing-cert.sh` sertifikayı giriş anahtar zincirinize ekler; bunun için anahtar zincirinin
kilidinin açılması gerekir, bu yüzden oturum parolanızı sorar (yazdıkça görünmez; yalnızca o çalıştırma
için kullanılır, saklanmaz ve yazdırılmaz). Etkileşimsiz kullanımda parolayı `KEYSHIFT_KEYCHAIN_PASSWORD`
ile verin ya da `--keychain <yol>` ile ayrı bir anahtar zinciri kullanın. Sertifika zaten varsa hiçbir
şey sorulmaz.

### İzinler

Keyshift, ilk açılışta **Sistem Ayarları → Gizlilik ve Güvenlik** bölümündeki iki izni açmanız
için sizi yönlendirir.

- **Erişilebilirlik** eşlenen kısayolları göndermek ve pencereleri yönetmek içindir.
- **Girdi İzleme** bastığınız tuşları okumak içindir.

Keyshift, Karabiner-Elements'ın çalıştığını algılarsa Ayarlar'da ve menü çubuğunda uyarı gösterir.
Tuşların iki kez eşlenmesini önlemek için Karabiner-Elements'tan çıkın veya kurallarını kapatın.

## Kullanım

Karşılama penceresinden hazır bir profil seçin. Menü çubuğundaki simgeden profil değiştirebilir,
eşlemeyi duraklatabilir veya **Ayarlar**'ı açabilirsiniz. Linux profili GNOME tarzı kısayollar
sunar. Terminal profili, desteklenen terminallerde sözcük ve satır içinde gezinme ile Ctrl+Shift+C/V
kısayollarını ekler. Ctrl+C, terminalde çalışan komutu kesmeye devam eder.

### Windows'tan gelenler için

**Windows** profilini seçin. Windows modundaki bir PC klavyesinde **Win, ⌘** ve **Alt, ⌥** olarak
çalışır.

| Tuşlar | İşlev |
|---|---|
| Ctrl+C/V/X ve diğer yaygın Ctrl kısayolları | Profilde istisna olarak tanımlanan terminal, oyun, sanal makine ve uzak masaüstü uygulamaları dışında ⌘ karşılıklarını gönderir |
| Home/End, Ctrl+←/→, Ctrl+Backspace | Satır başına/sonuna git, sözcükler arasında ilerle, önceki sözcüğü sil |
| Alt+F4 | Desteklenen uygulamalarda pencereyi kapat |
| Finder'da F2, Enter, Delete, Backspace | Dosyalara göz atarken yeniden adlandır, aç, Çöp Sepeti'ne taşı, üst klasöre git |
| Sol Win'e basıp bırakma | Spotlight'ı aç |
| Win+E, Win+L, Win+D | Finder'ı aç, ekranı kilitle, masaüstünü göster |
| Win+←/→, Win+Ctrl+←/→ | Pencereyi sola/sağa yerleştir, macOS Mission Control kısayollarıyla masaüstü değiştir |
| Print Screen (F13 olarak algılanıyorsa) | Ekran görüntüsü al |
| Ctrl+Shift+Esc | Etkinlik Monitörü'nü aç |
| Desteklenen tarayıcılarda Ctrl+L/J, F5, Ctrl+1–9 | Adres çubuğuna geç, eşleme varsa indirilenleri aç, sayfayı yenile, sekme seç |

## Ayarlar

Profilleri ve kuralları düzenlemek için menü çubuğundan **Ayarlar**'ı açın. Aynı ayarlar okunabilir
bir YAML dosyasında, `~/.config/keyshift/config.yaml` yolunda saklanır. Keyshift dosyayı izler ve
kaydettiğinizde yeniden yükler. Örneğin bu profil Finder'da dosyalara göz atarken F2'yi dosya
adını değiştirmek için kullanır.

```yaml
version: 1
profile: Kısayollarım
profiles:
  - name: Kısayollarım
    rules:
      - name: Finder'da yeniden adlandır
        only: [com.apple.finder]
        focus: not_text_input
        map:
          f2: return
```

Uygulama kapsamları, tuş adları ve eylemler için [ayar dosyası kılavuzuna](docs/CONFIG.md) bakın.

## Komut satırı

`--with-cli` seçeneğiyle kurduysanız şu komutları kullanabilirsiniz:

```sh
keyshift status                  # profili, eşleme durumunu ve izinleri göster
keyshift reload                  # çalışan uygulamada ayarları yeniden yükle
keyshift check [dosya]           # YAML dosyasını doğrula, çakışmaları göster
keyshift profile [ad]            # profilleri listele veya profil değiştir
keyshift import-karabiner [dosya] # karabiner.json dosyasını içe aktar
keyshift selftest [--suite]       # eşlemeyi dene veya Windows profili testlerini çalıştır
keyshift open [bölüm]            # Ayarlar'ı aç
keyshift --help                  # tüm seçenekleri göster
```

İçe aktarma komutu varsayılan olarak `~/.config/karabiner/karabiner.json` dosyasını okur.
Önce `--dry-run` ile rapora bakabilir, aktardıktan sonra da profile geçmeden önce kuralları
Ayarlar'da inceleyebilirsiniz.

## Sorun giderme

- **Kısayol çalışmıyor.** Etkin profili, izinleri ve Ayarlar'daki çakışma uyarılarını kontrol edin.
  Keyshift'in hangi tuşları gördüğünü olay görüntüleyicisinden izleyebilirsiniz. macOS'un güvenli
  giriş özelliği, parola alanlarında veya Terminal'de Güvenli Klavye Girişi açıkken eşlemeleri
  engelleyebilir.
- **Win çalışmıyor veya Win ile Alt yer değiştirmiş.** Windows profiliyle PC klavyenizin
  Windows/Mac anahtarından **Windows modunu** seçin. Oyun klavyelerinde **Win kilidi** olup
  olmadığına bakın. Bu kilit çoğu zaman **Fn+Win** ile açılıp kapanır.
- **`"` ve `<` tuşları yer değiştirmiş.** ISO klavyede bunlar 1'in ve sol Shift'in yanındaki
  tuşlardır. **Sistem Ayarları → Klavye → Klavye Türünü Değiştir** bölümünde **ISO**'yu seçin,
  ardından klavyeyi yeniden bağlayın. [Apple'ın klavye türü kılavuzu](https://support.apple.com/tr-tr/guide/mac-help/mchlp2886/mac).
- **Türkçe Q'da Chrome'da Ctrl+= yakınlaştırmıyor.** Bu düzende eşleme için gereken Shift'siz
  `=` tuşu yok. Ctrl+Eksi ile uzaklaştırabilir, Ctrl+0 ile yakınlaştırmayı sıfırlayabilirsiniz.
- **Yeniden derlemeden sonra izinler tekrar isteniyor.** Her derlemede aynı yerel imzayı kullanın
  veya `tccutil reset All io.github.ozanhakantunca.keyshift` komutunu çalıştırıp Keyshift'i
  yeniden açın ve izinleri tekrar verin.

## Kaldırma

Keyshift'ten çıkın ve uygulamayı Uygulamalar klasöründen Çöp Sepeti'ne taşıyın. Kaynak kod
klasöründe `./scripts/uninstall.sh` komutunu çalıştırırsanız komut satırı bağlantısı (elle kaldırmadan
sonra boşta kalmış olsa bile) da kaldırılır ve nelerin kaldırıldığı, nelerin kaldığı yazdırılır.
`~/.config/keyshift` klasörünü silmek için `--purge-config`, Erişilebilirlik ve Giriş İzleme izinlerini
sıfırlamak için `--reset-permissions` seçeneğini ekleyin.

Uygulamayı elle kaldırırsanız şunlar geride kalır:

- **Giriş öğesi.** Oturum açılışında başlatma açıksa (varsayılan) kaldırmadan önce Keyshift
  Ayarlar'ından kapatın ya da **Sistem Ayarları → Genel → Giriş Öğeleri ve Uzantılar** bölümünden
  Keyshift'i kaldırın.
- **İzinler.** **Gizlilik ve Güvenlik → Erişilebilirlik** ve **Giriş İzleme** listelerinden Keyshift'i
  kaldırın ya da `tccutil reset All io.github.ozanhakantunca.keyshift` komutunu çalıştırın.
- **Komut satırı bağlantısı.** `--with-cli` ile kurduysanız boşta kalan bağlantıyı silin:
  `rm /usr/local/bin/keyshift` veya `rm ~/.local/bin/keyshift`.
- **Ayarlar.** `rm -r ~/.config/keyshift`.

## Karabiner-Elements ile karşılaştırma

Keyshift, oturumunuzdaki kısayolları macOS'un olay yakalama arayüzü ve bir YAML dosyasıyla eşler.
Karabiner-Elements, DriverKit üzerinden sanal klavye kullanır ve aygıta özel kuralları destekler.
Keyshift'in kuralları tüm klavyeler için geçerlidir. Olay yakalamaya dayalı kurallar açık masaüstü
oturumunda çalışır. Elle düzenlemeniz gereken kurallar için içe aktarma raporuna bakın.
[Karabiner-Elements belgeleri](https://karabiner-elements.pqrs.org/docs/).

## Katkıda bulunma

Birim testleri CI'da çalışır. `scripts/e2e` testleri ise macOS oturumunda gerçek tuş ve fare
girdileri kullanır. [Test kılavuzu](docs/TESTING.md), [uçtan uca testler](scripts/e2e/README.md)
ve [katkı kılavuzu](CONTRIBUTING.md).

## Lisans

[GPL-3.0](LICENSE)
