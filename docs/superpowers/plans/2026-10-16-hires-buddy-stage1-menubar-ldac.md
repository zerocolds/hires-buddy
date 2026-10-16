# HiRes Buddy — этап 1: menubar-тумблер LDAC для системного звука

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Приложение в строке меню с тумблером «Hi-Res (LDAC)»: при включении звук любого приложения Mac уходит в наушники по LDAC, с переключателем 990/660/330 на лету и статусом потока на панели.

**Architecture:** Виртуальное аудиоустройство «HiRes Buddy» (форк BlackHole, HAL-плагин) принимает системный звук; приложение читает PCM с его input-стороны через CoreAudio IOProc, кодирует libldac и пишет RTP в L2CAP-сокет наушников. AVDTP-переговоры и каналы — перенос из прототипа `player/ldacplay.m` (приватный CBClassicPeer API; транспортный канал через helper-процесс + SCM_RIGHTS). UI — SwiftUI `MenuBarExtra`. Сборка — SwiftPM + скрипт сборки бандла, без Xcode-проекта (кроме драйвера, который собирается xcodebuild из подмодуля BlackHole).

**Tech Stack:** Swift 6.1 / SwiftUI (macOS 15 SDK), Objective-C (IOBluetooth, CoreBluetooth private API), C (libldac из `third_party/libldac`), CoreAudio HAL, BlackHole (git submodule), SwiftPM, `xcodebuild` только для драйвера.

**Spec:** `docs/superpowers/specs/2026-10-16-hires-buddy-design.md`

## Global Constraints

- macOS 15+, Apple Silicon; Swift 6 language mode с `-strict-concurrency=minimal` допустимо.
- Лицензия GPL-3.0; libldac остаётся нетронутым в `third_party/libldac` (Apache 2.0).
- Любой бандл, трогающий Bluetooth, обязан иметь `NSBluetoothAlwaysUsageDescription` в Info.plist.
- Никакой обработки звука кроме умножения на громкость и даунсемплинга >96 кГц. Этап 1 фиксирует частоту устройства и потока: **48 кГц** (следование за источником — этап 2).
- Этап 1 — только LDAC, только одно устройство: адрес берётся из настроек (`UserDefaults` ключ `headphoneAddress`, формат `xx-xx-xx-xx-xx-xx`), первично — из первого сопряжённого устройства с A2DP-сервисом, объявившего LDAC.
- Выключение тумблера и выход из приложения обязаны вернуть системный A2DP и прежнее устройство вывода (анти-цель спеки).
- Коммиты малые, с `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` в конце.

## Review Focus

1. Наушники отключились посреди потока (ушли к телефону, разряд): приложение обязано остановить поток, вернуть прежний выход, показать «отключены», не зависнуть и не крутить таймер. → Task 5 тест `testSinkDisconnectStopsStreamAndReports`.
2. Тумблер выключен или приложение закрыто во время потока: системный A2DP должен вернуться (наушники не остаются в HFP-only), выход переключён обратно. → Task 8 шаг ручной проверки + Task 5 `testStopSendsSuspendCloseAndReconnects`.
3. Переключение качества посреди потока: без щелчка и без обрыва; битрейт в панели меняется в течение 1 с. → Task 4 `testSetQualityMidStreamKeepsFrameContinuity`.
4. Переполнение сокета (эфир забит): `write()` блокирует; поток не должен копить задержку бесконечно — сбрасываем буфер до 250 мс и считаем провал. → Task 4 `testPacerDropsWhenBehind`.
5. Нет сопряжённых LDAC-наушников / адрес не задан: тумблер disabled с подсказкой, никаких крэшей на `nil` peer. → Task 7 `testNoDeviceDisablesToggle`.

---

## Структура файлов

```
Package.swift
Sources/
  CLDAC/                      C-таргет: module.modulemap + include/ldacBT.h → third_party/libldac
  LDACEncoder/                Swift: обёртка кодера
    LDACEncoder.swift
  BTStream/                   ObjC: Bluetooth-слой (перенос из player/ldacplay.m)
    include/BTStream.h        публичный заголовок (все классы ниже)
    HBL2CAPChannel.m          канал через CBClassicPeer, сокет, read/write
    HBAVDTP.m                 парсер/билдер сигналов AVDTP (чистые функции над байтами)
    HBAVDTPSession.m          state machine: discover→config→open→start / suspend / close
    HBTransportHelperClient.m запуск helper и приём fd (SCM_RIGHTS)
    HBPrivateAPI.h            объявления приватных селекторов CBClassicPeer/IOBluetoothDevice
  hiresbuddy-transport/       executable (ObjC): helper, открывает PSM 0x19 и отдаёт fd
    main.m
  HiResBuddyCore/             Swift: оркестрация
    RTPPacketizer.swift       RTP-заголовок + LDAC payload header
    StreamPacer.swift         темп отправки, буфер 250 мс, учёт провалов
    Streamer.swift            PCM in → encode → pace → socket; качество на лету; статистика
    AudioCapture.swift        CoreAudio IOProc с устройства «HiRes Buddy», громкость устройства
    OutputDeviceSwitcher.swift  default output device: сохранить/переключить/вернуть
    HeadphoneDiscovery.swift  поиск сопряжённых устройств с LDAC (SDP + GET_CAP)
    SessionController.swift   тумблер: takeover → stream → stop/restore; состояние для UI
  hiresbuddy-cli/             executable (Swift): `play <wav>`, `system`, `probe`
    main.swift
  HiResBuddy/                 executable (Swift/SwiftUI): menubar-приложение
    HiResBuddyApp.swift
    PanelView.swift
    Resources/Info.plist
Tests/
  LDACEncoderTests/ BTStreamTests/ HiResBuddyCoreTests/
driver/
  BlackHole/                  git submodule (ExistentialAudio/BlackHole)
  build.sh                    xcodebuild с kDriver_Name="HiRes Buddy", bundle id, 2 ch, 44100,48000,88200,96000
  install.sh                  sudo cp → /Library/Audio/Plug-Ins/HAL; restart coreaudiod
scripts/
  bundle.sh                   собирает HiResBuddy.app из swift build (app + helper + Info.plist), ad-hoc codesign
```

Прототип `player/` остаётся как есть (исторический артефакт); новый код его не импортирует.

---

### Task 1: Пакет и обёртка кодера LDAC

**Files:**
- Create: `Package.swift`, `Sources/CLDAC/module.modulemap`, `Sources/CLDAC/include/ldacBT.h` (символическая ссылка или копия `third_party/libldac/inc/ldacBT.h`), `Sources/CLDAC/*.c` → символические ссылки на `third_party/libldac/src/ldaclib.c`, `ldacBT.c`
- Create: `Sources/LDACEncoder/LDACEncoder.swift`
- Test: `Tests/LDACEncoderTests/LDACEncoderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum LDACQuality: Int, CaseIterable { case hq = 0, sq = 1, mq = 2 }   // = LDACBT_EQMID_*
  public enum LDACSampleRate: Int { case hz44100 = 44100, hz48000 = 48000, hz88200 = 88200, hz96000 = 96000
      public var avdtpBit: UInt8 }   // 0x20, 0x10, 0x08, 0x04
  public struct LDACPacket { public let frames: Int; public let bytes: [UInt8] }  // bytes = payload после RTP, БЕЗ 1-байтного заголовка
  public final class LDACEncoder {
      public init(sampleRate: LDACSampleRate, quality: LDACQuality, mtu: Int = 679) throws
      public var quality: LDACQuality { get set }            // ldacBT_set_eqmid на лету
      public var samplesPerFrame: Int { get }                // 128 @44.1/48, 256 @88.2/96
      /// interleaved stereo Float32, ровно 128 кадров (256 сэмплов); nil = ещё не накоплен пакет
      public func encode(_ pcm: UnsafeBufferPointer<Float>) throws -> LDACPacket?
      public func flush() throws -> LDACPacket?
      public static func nominalBitrate(quality: LDACQuality, sampleRate: LDACSampleRate) -> Int // кбит/с: 990/660/330 для 48/96, 909/606/303 для 44.1/88.2
  }
  ```
- Примечание: libldac принимает `LDACBT_SMPL_FMT_F32` — PCM отдаём как float без конвертации.

- [ ] **Step 1: Создать `Package.swift`** с таргетами из структуры файлов (пока только `CLDAC`, `LDACEncoder`, `LDACEncoderTests`; остальные добавляются в своих задачах). `CLDAC` — `cSettings: [.define("_32BIT_FIXED_POINT", to: nil)]` НЕ задавать (на Apple Silicon нужен float-путь). Платформа `.macOS(.v15)`.
- [ ] **Step 2: Написать падающие тесты**

```swift
func testEncoderProducesPacketsAtNominalBitrate() throws {
    let enc = try LDACEncoder(sampleRate: .hz48000, quality: .hq)
    var sine = [Float](repeating: 0, count: 256); for i in 0..<128 { let v = sinf(Float(i) * 0.1); sine[2*i] = v; sine[2*i+1] = v }
    var total = 0, frames = 0
    for _ in 0..<2000 { if let p = try sine.withUnsafeBufferPointer({ try enc.encode($0) }) { total += p.bytes.count; frames += p.frames } }
    XCTAssertEqual(enc.samplesPerFrame, 128)
    let seconds = Double(frames * 128) / 48000
    let kbps = Double(total * 8) / seconds / 1000
    XCTAssert((900...1000).contains(kbps), "\(kbps)")
}
func testQualityChangeMidStreamChangesBitrate() throws  // 500 блоков hq, переключить .mq, 500 блоков — второй сегмент < 400 кбит/с
func testNominalBitrateTable()  // hq/48k == 990, hq/44.1k == 909, sq/96k == 660, mq/44.1k == 303
func testRejectsWrongBlockSize()  // 100 кадров → throws
```

- [ ] **Step 3: Запустить `swift test --filter LDACEncoderTests`** — ожидается ошибка компиляции (нет модуля).
- [ ] **Step 4: Реализовать `LDACEncoder.swift`** по интерфейсу; `encode` вызывает `ldacBT_encode(handle, pcm, &used, out, &wrote, &fn)` и возвращает пакет, когда `wrote > 0`.
- [ ] **Step 5: `swift test --filter LDACEncoderTests`** — PASS.
- [ ] **Step 6: Commit** `feat: SwiftPM package with LDAC encoder wrapper`.

---

### Task 2: BTStream — AVDTP-парсер и L2CAP-канал

**Files:**
- Create: `Sources/BTStream/include/BTStream.h`, `Sources/BTStream/HBPrivateAPI.h`, `Sources/BTStream/HBAVDTP.m`, `Sources/BTStream/HBL2CAPChannel.m`
- Test: `Tests/BTStreamTests/HBAVDTPTests.m` (XCTest на ObjC)

**Interfaces:**
- Consumes: ничего.
- Produces (в `BTStream.h`):
  ```objc
  typedef NS_ENUM(uint8_t, HBAVDTPSignal) { HBAVDTPDiscover = 1, HBAVDTPGetCapabilities = 2, HBAVDTPSetConfiguration = 3, HBAVDTPOpen = 6, HBAVDTPStart = 7, HBAVDTPClose = 8, HBAVDTPSuspend = 9, HBAVDTPAbort = 10 };
  @interface HBAVDTPEndpoint : NSObject
  @property uint8_t seid; @property BOOL inUse; @property BOOL isSink;
  @property BOOL supportsLDAC; @property uint8_t ldacSampleRates; @property uint8_t ldacChannelModes;  // из GET_CAP
  @end
  @interface HBAVDTP : NSObject
  + (NSData *)command:(HBAVDTPSignal)sig label:(uint8_t)label payload:(NSData *)payload;         // [label<<4|0x00, sig, payload]
  + (NSData *)acceptResponseForCommand:(NSData *)cmd;                                              // [hdr&0xf0|0x02, sig]
  + (BOOL)parseHeader:(NSData *)msg label:(uint8_t *)label messageType:(uint8_t *)type signal:(HBAVDTPSignal *)sig;
  + (NSArray<HBAVDTPEndpoint *> *)parseDiscover:(NSData *)rsp;
  + (void)parseCapabilities:(NSData *)rsp into:(HBAVDTPEndpoint *)ep;  // ищет category 7, vendor 0x012D codec 0x00AA
  + (NSData *)setConfigurationPayloadForSEID:(uint8_t)acp intSEID:(uint8_t)intSeid ldacSampleRateBit:(uint8_t)sfBit channelModeBit:(uint8_t)cmBit;
  @end
  @protocol HBL2CAPChannelDelegate <NSObject>
  - (void)channel:(HBL2CAPChannel *)c didReceive:(NSData *)data;
  - (void)channelDidClose:(HBL2CAPChannel *)c;
  @end
  @interface HBL2CAPChannel : NSObject
  /// Открывает PSM на уже подключённом устройстве через CBClassicPeer (см. HBPrivateAPI.h). completion на main queue.
  + (void)openPSM:(uint16_t)psm onDevice:(IOBluetoothDevice *)dev completion:(void (^)(HBL2CAPChannel * _Nullable ch, NSInteger code))completion;
  /// Оборачивает уже готовый сокет (fd от helper).
  - (instancetype)initWithSocketFD:(int)fd name:(NSString *)name;
  @property(weak) id<HBL2CAPChannelDelegate> delegate;
  @property(readonly) int socketFD;
  @property(readonly) uint16_t outgoingMTU;
  - (BOOL)write:(NSData *)data;   // один write() = один SDU; NO при short write/ошибке
  - (void)close;
  @end
  ```
- `HBPrivateAPI.h`: `@interface IOBluetoothDevice (HBPriv) - (id)classicPeer; @end` и `@interface HBClassicPeerShim : NSObject - (void)setConnectL2CAPCallback:(void (^)(CBL2CAPChannel *, long))cb; - (id)openL2CAPChannel:(unsigned long)psm; @end`.

- [ ] **Step 1: Тесты парсера на реальных байтах из прототипа**

```objc
- (void)testParseDiscoverFromXM4 {   // 12 01 04 08 08 08 0c 08 10 08 14 08 18 08
    NSArray *eps = [HBAVDTP parseDiscover:HEX(@"12 01 04 08 08 08 0c 08 10 08 14 08 18 08")];
    XCTAssertEqual(eps.count, 6); XCTAssertEqual(((HBAVDTPEndpoint *)eps[2]).seid, 3); XCTAssertTrue(((HBAVDTPEndpoint *)eps[2]).isSink);
}
- (void)testParseLDACCapabilities {   // 42 02 01 00 07 0a 00 ff 2d 01 00 00 aa 00 3c 07 04 02 02 00
    HBAVDTPEndpoint *ep = [HBAVDTPEndpoint new]; [HBAVDTP parseCapabilities:HEX(@"42 02 01 00 07 0a 00 ff 2d 01 00 00 aa 00 3c 07 04 02 02 00") into:ep];
    XCTAssertTrue(ep.supportsLDAC); XCTAssertEqual(ep.ldacSampleRates, 0x3c); XCTAssertEqual(ep.ldacChannelModes, 0x07);
}
- (void)testParseAACCapabilitiesIsNotLDAC   // 32 02 01 00 07 08 00 02 c0 01 8c 84 e2 00 04 02 02 00 → supportsLDAC == NO
- (void)testSetConfigurationPayloadMatchesPrototype {  // acp 3, int 1, 96k (0x04), stereo (0x01)
    XCTAssertEqualObjects([HBAVDTP setConfigurationPayloadForSEID:3 intSEID:1 ldacSampleRateBit:0x04 channelModeBit:0x01],
                          HEX(@"0c 04 01 00 07 0a 00 ff 2d 01 00 00 aa 00 04 01"));
}
- (void)testCommandAndAcceptFraming   // command:Discover label:1 → "10 01"; accept для "00 0d" (delay report cmd, label 0) → "02 0d"
- (void)testParseHeaderRejectIs0x03   // "73 01 31" → type 3, sig 1
```

- [ ] **Step 2: `swift test --filter HBAVDTPTests`** — FAIL (нет модуля).
- [ ] **Step 3: Реализовать `HBAVDTP.m` и `HBL2CAPChannel.m`.** Канал: перенос `Chan` из `player/ldacplay.m` (NSStream на `inputStream`/`outputStream` для чтения; запись — `write(socketFD)`), открытие — перенос `openSignalingOn:` (peer callback → completion). `initWithSocketFD:` строит `NSInputStream` через `CFStreamCreatePairWithSocket`.
- [ ] **Step 4: `swift test --filter HBAVDTPTests`** — PASS.
- [ ] **Step 5: Commit** `feat(BTStream): AVDTP codec and CoreBluetooth-direct L2CAP channel`.

---

### Task 3: Helper транспортного канала и его клиент

**Files:**
- Create: `Sources/hiresbuddy-transport/main.m`, `Sources/hiresbuddy-transport/Info.plist` (NSBluetoothAlwaysUsageDescription), `Sources/BTStream/HBTransportHelperClient.m`
- Test: `Tests/BTStreamTests/HBTransportHelperClientTests.m`

**Interfaces:**
- Consumes: `HBL2CAPChannel openPSM:onDevice:completion:` (Task 2).
- Produces:
  ```objc
  @interface HBTransportHelperClient : NSObject
  - (instancetype)initWithHelperURL:(NSURL *)helper;     // по умолчанию: Bundle.main.executableURL.deletingLastPathComponent + "hiresbuddy-transport"
  /// Запускает helper (stdin pipe, unix socket /tmp/hiresbuddy-<pid>.sock), шлёт "OPEN <addr> <psm>\n", ждёт fd. completion на main.
  - (void)openTransportForAddress:(NSString *)addr psm:(uint16_t)psm completion:(void (^)(int fd, NSInteger code))completion;
  - (void)terminate;   // убивает helper → канал закрывается
  @end
  ```
- Протокол helper: stdin строка `OPEN <addr> <psm>`; helper открывает канал через `HBL2CAPChannel`, подключается к unix-сокету из argv[1], шлёт 1 байт (1=ok,0=fail) + SCM_RIGHTS с fd; живёт, пока stdin не закроется (держит `CBL2CAPChannel`).

- [ ] **Step 1: Тест передачи fd без Bluetooth** — `HBTransportHelperClient` с `helperURL` на тестовый скрипт `Tests/BTStreamTests/fake-helper.sh`, который по `OPEN` подключается к сокету и шлёт fd от `/dev/null` (реализовать fake-helper как маленький ObjC/Swift-executable таргет `fake-transport` в Tests, т.к. shell не умеет SCM_RIGHTS):

```objc
- (void)testReceivesFileDescriptorFromHelper {
    XCTestExpectation *e = [self expectationWithDescription:@"fd"];
    [client openTransportForAddress:@"00-00-00-00-00-00" psm:0x19 completion:^(int fd, NSInteger code) {
        XCTAssertGreaterThan(fd, 0); XCTAssertEqual(code, 0);
        struct stat st; XCTAssertEqual(fstat(fd, &st), 0); [e fulfill]; }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
}
- (void)testHelperFailureReportsCode   // fake-helper с env FAKE_FAIL=24 → fd == -1, code == 24
```

- [ ] **Step 2: Запустить** — FAIL.
- [ ] **Step 3: Реализовать helper и клиент** (перенос `spawnHelper`/`requestTransport`/`runTransportHelper` из прототипа, адрес и PSM — из команды, не из константы).
- [ ] **Step 4: Запустить** — PASS.
- [ ] **Step 5: Commit** `feat(BTStream): transport helper process with SCM_RIGHTS handover`.

---

### Task 4: AVDTP-сессия, пакетизация и темп

**Files:**
- Create: `Sources/BTStream/HBAVDTPSession.m`, `Sources/HiResBuddyCore/RTPPacketizer.swift`, `Sources/HiResBuddyCore/StreamPacer.swift`
- Test: `Tests/BTStreamTests/HBAVDTPSessionTests.m`, `Tests/HiResBuddyCoreTests/RTPPacketizerTests.swift`, `Tests/HiResBuddyCoreTests/StreamPacerTests.swift`

**Interfaces:**
- Consumes: Task 2 (`HBAVDTP`, `HBL2CAPChannel`), Task 3 (`HBTransportHelperClient`), Task 1 (`LDACPacket`).
- Produces:
  ```objc
  typedef NS_ENUM(NSInteger, HBSessionState) { HBSessionIdle, HBSessionConnecting, HBSessionConfigured, HBSessionStreaming, HBSessionSuspended, HBSessionClosed, HBSessionFailed };
  @protocol HBAVDTPSessionDelegate <NSObject>
  - (void)session:(HBAVDTPSession *)s didChangeState:(HBSessionState)state error:(NSError * _Nullable)err;
  @end
  @interface HBAVDTPSession : NSObject
  - (instancetype)initWithDevice:(IOBluetoothDevice *)dev helper:(HBTransportHelperClient *)helper;
  @property(weak) id<HBAVDTPSessionDelegate> delegate;
  @property(readonly) HBSessionState state;
  @property(readonly) int transportFD;               // валиден в Streaming/Suspended
  @property(readonly) uint16_t transportMTU;
  @property(readonly) uint8_t negotiatedSampleRateBit;
  /// Полный путь до Streaming: takeover при необходимости (closeConnection → openPSM с ретраями 8×2 с), discover, конфиг LDAC, open, transport, start.
  - (void)startWithSampleRateBit:(uint8_t)sfBit;
  - (void)suspend; - (void)resume;
  /// SUSPEND+CLOSE, закрыть каналы, terminate helper, затем [dev closeConnection] + [dev openConnection:] чтобы macOS вернула A2DP.
  - (void)stopAndRestoreSystemAudio;
  @end
  ```
  ```swift
  public struct RTPPacketizer {
      public init(ssrc: UInt32 = 1, payloadType: UInt8 = 0x60)
      public mutating func packet(for p: LDACPacket, timestamp: UInt32) -> [UInt8]   // 12-байт RTP + [frames&0x0f] + bytes; seq++
      public private(set) var sequence: UInt16
  }
  public final class StreamPacer {
      public init(sampleRate: Int, samplesPerFrame: Int, leadSeconds: Double = 0.25, now: @escaping () -> Double)
      public func start()
      /// Возвращает true, если пакет пора отправлять. Если отставание > 2×lead — сбрасывает учёт и инкрементирует dropEvents.
      public func shouldSend(framesAlreadySent: Int) -> Bool
      public private(set) var dropEvents: Int
  }
  ```
- Правила сессии (из прототипа): stray reject (`type 3`) в Streaming — игнорировать; команда от стока (type 0, например Delay Report 0x0d) — отвечать accept; закрытие сигнального канала в Streaming → `Failed` с ошибкой `HBErrorSinkDisconnected`.

- [ ] **Step 1: Тесты сессии через фейковый канал** — в `HBAVDTPSession` добавить инициализатор для тестов `initWithSignalingChannel:(HBL2CAPChannel *)sig transportProvider:(void(^)(void(^)(int fd)))provider`, где фейковый `HBL2CAPChannel`-наследник записывает отправленное и позволяет тесту «ответить»:

```objc
- (void)testHappyPathReachesStreaming {   // discover rsp → getcap×3 (SBC, AAC, LDAC из прототипа) → setconf accept → open accept → provider даёт fd → start accept
    [session startWithSampleRateBit:0x10]; [fake reply:HEX(@"12 01 04 08 08 08 0c 08 10 08 14 08 18 08")]; ...
    XCTAssertEqual(session.state, HBSessionStreaming); XCTAssertEqual(fake.sent.lastObject.bytes[1], HBAVDTPStart);
}
- (void)testStrayRejectWhileStreamingIsIgnored      // после Streaming: reply "73 01 31" → state остаётся Streaming
- (void)testSinkCommandIsAccepted                     // reply "00 0d ..." → sent.lastObject == "02 0d"
- (void)testSinkDisconnectStopsStreamAndReports      // fake закрывает сигнальный канал → Failed, error.code == HBErrorSinkDisconnected
- (void)testStopSendsSuspendCloseAndReconnects       // stopAndRestoreSystemAudio → sent содержит Suspend, Close; вызван restore-hook (инжектируемый блок, по умолчанию close/openConnection)
- (void)testNoLDACEndpointFails                       // getcap только SBC/AAC → Failed, HBErrorNoLDAC
```

- [ ] **Step 2: Тесты пакетизатора и пейсера**

```swift
func testRTPHeaderMatchesPrototype() {   // seq 0, ts 0, ssrc 1, pt 0x60 → 80 60 00 00 00 00 00 00 00 00 00 01, затем frames-байт
    var p = RTPPacketizer(); let out = p.packet(for: LDACPacket(frames: 2, bytes: [0xAA]), timestamp: 0)
    XCTAssertEqual(Array(out.prefix(12)), [0x80,0x60,0,0, 0,0,0,0, 0,0,0,1]); XCTAssertEqual(out[12], 2); XCTAssertEqual(out[13], 0xAA); XCTAssertEqual(p.sequence, 1)
}
func testPacerKeepsLead()            // now=0: отправляет пока sent*spf/sr < 0.25; затем false
func testPacerDropsWhenBehind()      // now скачет на +1.0 с при 0 отправленных → dropEvents == 1, затем shouldSend true
func testSetQualityMidStreamKeepsFrameContinuity()  // в HiResBuddyCoreTests: Streamer-уровень (Task 5) — перенести туда, здесь только заглушка-ссылка
```

- [ ] **Step 3: Запустить оба набора** — FAIL.
- [ ] **Step 4: Реализовать** `HBAVDTPSession.m` (перенос `handleSig`/`start`/`channelOpened`/retries из прототипа в явный state machine), `RTPPacketizer.swift`, `StreamPacer.swift`.
- [ ] **Step 5: Запустить** — PASS.
- [ ] **Step 6: Commit** `feat: AVDTP session state machine, RTP packetizer, stream pacer`.

---

### Task 5: Streamer + CLI `play` (сквозная проверка на XM4)

**Files:**
- Create: `Sources/HiResBuddyCore/Streamer.swift`, `Sources/hiresbuddy-cli/main.swift`, `Sources/hiresbuddy-cli/Info.plist`
- Test: `Tests/HiResBuddyCoreTests/StreamerTests.swift`

**Interfaces:**
- Consumes: Task 1 `LDACEncoder`, Task 4 `HBAVDTPSession`, `RTPPacketizer`, `StreamPacer`.
- Produces:
  ```swift
  public struct StreamStats: Sendable { public var packets: Int; public var dropEvents: Int; public var bitrateKbps: Int; public var sampleRate: Int; public var quality: LDACQuality; public var uptime: TimeInterval; public var bufferSeconds: Double }
  public protocol PCMSource: AnyObject { func start(_ sink: @escaping (UnsafeBufferPointer<Float>) -> Void); func stop() }   // interleaved stereo float, любые размеры блоков
  @MainActor public final class Streamer {
      public init(session: HBAVDTPSession, sampleRate: LDACSampleRate, quality: LDACQuality)
      public var quality: LDACQuality { get set }       // на лету
      public var gain: Float { get set }                // 0…1, применяется к PCM перед кодером
      public private(set) var stats: StreamStats
      public var onStats: ((StreamStats) -> Void)?       // раз в 1 с
      public func start(source: PCMSource) throws        // session.startWithSampleRateBit → по Streaming запускает source
      public func stop()                                 // source.stop, session.stopAndRestoreSystemAudio
  }
  ```
  Внутри: блоки от источника режутся на 128 кадров через накопительный буфер; `write(session.transportFD)` в отдельной `DispatchQueue(label: "stream", qos: .userInteractive)`; таймер 4 мс как в прототипе.
- CLI: `hiresbuddy-cli play <wav> [--addr xx-..] [--quality hq|sq|mq]` (WAV-источник, реализует `PCMSource` чтением файла с реальным темпом), `hiresbuddy-cli probe` (Task 6).

- [ ] **Step 1: Тесты Streamer с фейковой сессией (без BT)** — `HBAVDTPSession` подменяется наследником, у которого `transportFD` = один конец `socketpair`, а `startWithSampleRateBit:` сразу переводит в Streaming:

```swift
func testStreamsPacketsToTransportFD()                // 1 с синуса → на другом конце socketpair читаем ≥ 150 пакетов с заголовком 80 60
func testSetQualityMidStreamKeepsFrameContinuity()     // переключить hq→mq на 0.5 с: seq монотонна без разрывов, bitrate в stats упал
func testGainIsAppliedBeforeEncode()                  // gain 0 → кодер получает тишину (проверка через инжектируемый энкодер-шпион)
func testStatsReportBitrateWithinTolerance()          // hq/48k: 900…1000 кбит/с через 2 с
```

- [ ] **Step 2: Запустить** — FAIL.
- [ ] **Step 3: Реализовать `Streamer.swift` и CLI `play`.**
- [ ] **Step 4: Запустить тесты** — PASS.
- [ ] **Step 5: Ручная проверка на XM4:** `swift build && .build/debug/hiresbuddy-cli play player/../media/track.wav --addr <XM4> --quality sq` (бинарь должен иметь Info.plist с NSBluetoothAlwaysUsageDescription — через `-Xlinker -sectcreate` в `linkerSettings` таргета). Ожидается: звук в наушниках, в консоли статистика раз в секунду, Ctrl-C → наушники возвращаются в системный AAC (проверить `system_profiler SPBluetoothDataType | grep -A8 WH-1000 | grep Services` содержит A2DP).
- [ ] **Step 6: Commit** `feat: Streamer and hiresbuddy-cli play — end-to-end LDAC playback`.

---

### Task 6: Поиск наушников с LDAC и переключение устройства вывода

**Files:**
- Create: `Sources/HiResBuddyCore/HeadphoneDiscovery.swift`, `Sources/HiResBuddyCore/OutputDeviceSwitcher.swift`
- Modify: `Sources/hiresbuddy-cli/main.swift` (команда `probe`)
- Test: `Tests/HiResBuddyCoreTests/OutputDeviceSwitcherTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct Headphones: Identifiable, Hashable { public let id: String /* addr xx-xx-.. */; public let name: String; public let isConnected: Bool; public let ldacSampleRates: UInt8? /* nil = ещё не опрошены */ }
  public enum HeadphoneDiscovery {
      public static func pairedA2DPDevices() -> [Headphones]     // IOBluetoothDevice.pairedDevices с SDP-сервисом 0x110B
      public static func probeLDAC(_ h: Headphones) async -> Headphones   // открывает сигнальный канал, DISCOVER+GET_CAP, закрывает; только если isConnected
  }
  public final class OutputDeviceSwitcher {
      public init()
      public func deviceID(named name: String) -> AudioDeviceID?
      public func current() -> AudioDeviceID
      public func switchTo(_ id: AudioDeviceID) throws       // запоминает previous при первом вызове
      public func restore() throws                           // возвращает previous, если тот ещё существует; иначе no-op
  }
  ```

- [ ] **Step 1: Тест switcher** (реальная CoreAudio, без драйвера): `testSwitchToCurrentAndRestoreIsNoop` — `switchTo(current())`, `restore()` не бросает, `current()` не изменился. `testUnknownNameReturnsNil`.
- [ ] **Step 2: Запустить** — FAIL. **Step 3: Реализовать** (`kAudioHardwarePropertyDefaultOutputDevice`, `kAudioObjectPropertyName`). **Step 4: PASS.**
- [ ] **Step 5: `hiresbuddy-cli probe`** печатает сопряжённые A2DP-устройства и для подключённых — поддержку LDAC и частоты. Ручная проверка на XM4: строка `WH-1000XM4 94-db-… connected LDAC 44.1/48/88.2/96`.
- [ ] **Step 6: Commit** `feat: LDAC headphone discovery and default output switcher`.

---

### Task 7: Драйвер «HiRes Buddy» и захват PCM

**Files:**
- Create: `driver/build.sh`, `driver/install.sh`, `driver/uninstall.sh`, git submodule `driver/BlackHole`
- Create: `Sources/HiResBuddyCore/AudioCapture.swift`
- Modify: `Sources/hiresbuddy-cli/main.swift` (команда `system`)
- Test: `Tests/HiResBuddyCoreTests/AudioCaptureTests.swift` (пропускается, если устройства нет)

**Interfaces:**
- Produces:
  ```swift
  public final class AudioCapture: PCMSource {
      public static let deviceName = "HiRes Buddy"
      public init(deviceName: String = AudioCapture.deviceName, sampleRate: Int) throws   // throws HBError.deviceNotInstalled
      public func start(_ sink: @escaping (UnsafeBufferPointer<Float>) -> Void)   // AudioDeviceCreateIOProcID на input-стороне; блоки как даёт HAL
      public func stop()
      public var deviceVolume: Float { get }    // kAudioDevicePropertyVolumeScalar output scope; если нет свойства — 1.0
      public func onVolumeChange(_ f: @escaping (Float) -> Void)   // listener на свойство
  }
  ```
- `driver/build.sh`: `xcodebuild -project driver/BlackHole/BlackHole.xcodeproj -configuration Release PRODUCT_BUNDLE_IDENTIFIER=dev.hiresbuddy.driver GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS kDriver_Name=\"HiResBuddy\" kPlugIn_BundleID=\"dev.hiresbuddy.driver\" kDevice_Name=\"HiRes Buddy\" kNumber_Of_Channels=2 kSampleRates=44100,48000,88200,96000 kDevice2_IsHidden=true'` → `build/HiResBuddy.driver`. Если в текущем BlackHole громкость не поддерживается (нет `kEnableVolumeControl`/аналога) — оставить `deviceVolume` на 1.0 и зафиксировать это в README как известное ограничение (этап 2).
- `driver/install.sh`: `sudo cp -R build/HiResBuddy.driver /Library/Audio/Plug-Ins/HAL/ && sudo killall -9 coreaudiod`.

- [ ] **Step 1: Добавить submodule** `git submodule add https://github.com/ExistentialAudio/BlackHole driver/BlackHole`, написать `build.sh`, собрать, `install.sh`. Проверка: `system_profiler SPAudioDataType | grep -A3 "HiRes Buddy"` показывает устройство с input и output.
- [ ] **Step 2: Тест захвата** — `testCaptureDeliversSilenceWhenNothingPlays`: если устройство есть — за 0.5 с приходит ≥ 1 блок, все сэмплы == 0; иначе `XCTSkip`.
- [ ] **Step 3: FAIL → реализовать `AudioCapture.swift` → PASS.**
- [ ] **Step 4: `hiresbuddy-cli system --addr <XM4> --quality sq`**: switcher переключает default output на «HiRes Buddy», стример берёт PCM из `AudioCapture`, при Ctrl-C — `restore()` + `stopAndRestoreSystemAudio`. Ручная проверка: VOX играет FLAC → слышно в наушниках по LDAC; клавиши громкости Mac меняют громкость (если драйвер отдаёт volume); Ctrl-C → звук возвращается на прежний выход, наушники снова в AAC.
- [ ] **Step 5: Commit** `feat: HiRes Buddy virtual device (BlackHole fork) and system audio capture`.

---

### Task 8: SessionController и menubar-приложение

**Files:**
- Create: `Sources/HiResBuddyCore/SessionController.swift`, `Sources/HiResBuddy/HiResBuddyApp.swift`, `Sources/HiResBuddy/PanelView.swift`, `Sources/HiResBuddy/Resources/Info.plist` (LSUIElement=true, NSBluetoothAlwaysUsageDescription), `scripts/bundle.sh`
- Test: `Tests/HiResBuddyCoreTests/SessionControllerTests.swift`

**Interfaces:**
- Consumes: Task 5 `Streamer`, Task 6 `HeadphoneDiscovery`/`OutputDeviceSwitcher`, Task 7 `AudioCapture`.
- Produces:
  ```swift
  @MainActor public final class SessionController: ObservableObject {
      public enum Phase: Equatable { case off, connecting, streaming, stopping, error(String) }
      @Published public private(set) var phase: Phase
      @Published public var headphones: [Headphones]; @Published public var selected: Headphones?   // persist: UserDefaults "headphoneAddress"
      @Published public var quality: LDACQuality            // persist: "defaultQuality"; при streaming → streamer.quality
      @Published public private(set) var stats: StreamStats?
      public var canEnable: Bool { selected?.isConnected == true && driverInstalled }
      public var driverInstalled: Bool
      public init(makeSession: @escaping (IOBluetoothDevice) -> HBAVDTPSession = …, makeCapture: … , switcher: OutputDeviceSwitcher = .init())
      public func setEnabled(_ on: Bool)      // on: switcher.switchTo(HiRes Buddy) → streamer.start(capture); off/exit: streamer.stop(), switcher.restore()
      public func refreshHeadphones() async
  }
  ```
- Панель (`PanelView`): заголовок с именем и статусом; `Toggle("Hi-Res (LDAC)")` привязан к `setEnabled`, disabled если `!canEnable` с подсказкой «Подключите наушники с LDAC» / «Установите драйвер» и кнопкой «Установить драйвер…» (запускает `driver/install.sh` через `osascript … with administrator privileges`); `Picker` 990/660/330 (segmented), подписи битрейта по `LDACEncoder.nominalBitrate`; статистика: «LDAC · 48 kHz · 660 kbps», пакеты, провалы, аптайм, буфер; `Picker` устройств; кнопка «Выход» (вызывает `setEnabled(false)` перед `NSApp.terminate`). `MenuBarExtra("HiRes Buddy", systemImage: "headphones")` со стилем `.window`.
- `scripts/bundle.sh`: `swift build -c release`; собирает `build/HiResBuddy.app/Contents/{MacOS/HiResBuddy, MacOS/hiresbuddy-transport, Info.plist}`; `codesign --force --sign - --deep`.

- [ ] **Step 1: Тесты контроллера с фейками** (session/capture инжектируются):

```swift
func testNoDeviceDisablesToggle()                    // headphones == [] → canEnable false; setEnabled(true) не меняет phase
func testEnableSwitchesOutputAndStartsStream()       // phase: connecting → streaming; switcher.switchTo вызван с id «HiRes Buddy»
func testDisableRestoresOutputAndSystemAudio()       // phase off; switcher.restore вызван; session.stop вызван
func testSessionFailureGoesToErrorAndRestores()      // фейк сессии шлёт Failed(SinkDisconnected) → phase == .error, restore вызван
func testQualityChangePropagatesWhileStreaming()
```

- [ ] **Step 2: FAIL → реализовать контроллер → PASS.**
- [ ] **Step 3: Реализовать приложение и `bundle.sh`.** Запуск: `scripts/bundle.sh && open build/HiResBuddy.app`.
- [ ] **Step 4: Ручная проверка на XM4** (это приёмка этапа): иконка в строке меню; выбрать XM4; тумблер → наушники переподключаются, VOX играет в LDAC; переключить 990/660/330 во время трека — без обрыва, битрейт в панели обновился; выключить тумблер → VOX продолжает играть в прежний выход, наушники в AAC (`Services` содержит A2DP); Выход из приложения во время потока → то же самое.
- [ ] **Step 5: Обновить README** (сборка драйвера, бандла, статус «этап 1»), **Commit** `feat: HiRes Buddy menu bar app — LDAC toggle, quality, stream stats`, push.

---

## Самопроверка

- Спека, этап 1: тумблер (Task 8), виртуальное устройство (Task 7), любой плеер → LDAC (Task 7/8), качество на лету (Task 1/5/8), статус потока (Task 5/8), выбор устройства (Task 6/8), возврат системного A2DP (Task 4/8), громкость Mac (Task 7, с оговоркой про поддержку в BlackHole). Авто-режим, следование за частотой, aptX HD, AVRCP, Control Center — вне этого плана по решению scope.
- Имена: `HBAVDTPSession.stopAndRestoreSystemAudio` (Task 4) используется в Task 5/8; `AudioCapture: PCMSource` (Task 7) — в Task 5 определён протокол; `LDACPacket.frames/bytes` (Task 1) — в Task 4 `RTPPacketizer`.
- Review Focus 1–5 закреплены тестами в Task 4, 4, 5, 4, 8.
