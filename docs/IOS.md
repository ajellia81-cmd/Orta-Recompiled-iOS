# iOS 포팅 (iPhone / iPad)

판처 드라군 오르타를 iPhone과 iPad에서 네이티브로 실행해요. PC판·안드로이드판과 같은 재컴파일 코드와 툴킷
(xboxrecomp-option-c v1.1.1)을 쓰고, Vulkan 렌더러는 MoltenVK를 거쳐 Metal로 돌아가요. 서명하지 않은
`OrtaRecomp.ipa`를 만들기 때문에 **LiveContainer**로 바로 설치할 수 있어요. 빌드 구조는 로스트 월드 iOS 포팅과
같아요.

> 실험 단계예요. 아직 실제 기기에서 확인하지 않았어요.

## 안드로이드판과 다른 점: 게임 코드는 빌드할 때 들어가요

안드로이드판은 폰에서 디스크를 번역·컴파일해요. iOS 앱은 자기가 만든 코드를 실행할 수 없어서, `default.xbe`에서
게임 코드를 뽑아 컴파일하는 일(lift)을 **빌드하는 Mac(또는 GitHub의 macOS 서버)** 에서 해요. 그래서 만든 앱에는
디스크에서 나온 코드가 들어 있어요. **공개된 곳에 올리면 안 돼요.** 디스크의 나머지 파일(영상, 음성, 텍스처)은 앱에
넣지 않고 폰에 따로 넣어요.

## GitHub에서 빌드 (Mac 없이)

이 저장소의 Actions가 GitHub의 macOS 서버에서 `tools/build_ios.sh`로 .ipa를 만들어요 (`.github/workflows/ios.yml`).
이 저장소에는 소스 코드만 있어서 공개해도 돼요. `default.xbe`와 만든 앱은 **비공개 저장소**(이 저장소 이름 +
`-private`)에만 둬요.

1. **비공개 저장소 (한 번만)**: 파일 하나(README 등)를 넣어 만들고, 태그 `xbe` 릴리스에 `default.xbe`를 첨부해요.
   유럽(PAL)판만 돼요. SHA-1이 `57213ff35a19807def664f9018cc2923815dfa1f`여야 해요.
2. **토큰 (한 번만)**: Fine-grained 토큰을 그 저장소에만, Contents: Read and write 권한으로 만들어
   이 저장소의 Actions 시크릿 `PRIVATE_REPO_TOKEN`에 넣어요.
3. **빌드**: Actions > iOS build > Run workflow를 누르고 `ipa`를 골라요. 첫 빌드는 의존성(SDL3, glslang, MoltenVK)
   까지 만드느라 오래 걸려요.
4. **받기**: 비공개 저장소의 릴리스 `latest`에 `OrtaRecomp.ipa`가 올라와요 (빌드할 때마다 바뀌어요).

`check`를 고르면 `default.xbe` 없이 툴킷 런타임과 포트 소스가 iOS용으로 컴파일되는지만 확인해요.

### default.xbe 꺼내기

디스크 이미지(.iso)에서 `default.xbe` 하나만 꺼내면 돼요. PC판을 돌린 적이 있으면 설치 폴더의
`game\default.xbe`를 그대로 써도 돼요. 아니면 다음 중 하나로 꺼내요.

- [extract-xiso](https://github.com/XboxDev/extract-xiso/releases): `extract-xiso -d out Orta.iso`
- 툴킷의 추출기: `python3 -m tools.xiso get Orta.iso default.xbe -o out` (xboxrecomp-option-c 폴더에서)
- 웹 도구 [xiso.antangelo.com](https://xiso.antangelo.com)

## 빌드 (Mac)

필요한 것: Xcode(한 번 실행해서 iOS SDK 설치), Homebrew의 `cmake`, `ninja`, `python`(3.11 이상), `default.xbe`.

```
brew install cmake ninja python
tools/build_ios.sh /경로/default.xbe
```

결과물은 `out/ios/OrtaRecomp.ipa`예요. 스크립트는 툴킷을 받아 iOS 패치를 적용하고, `default.xbe`를 lift하고,
SDL3·glslang·MoltenVK를 iOS용으로 준비한 뒤 arm64 iOS로 크로스 컴파일해서 .ipa로 묶어요.

## LiveContainer로 설치

1. `OrtaRecomp.ipa`를 AirDrop이나 파일 앱으로 폰에 옮겨요.
2. LiveContainer에서 **+** 를 눌러 .ipa를 추가하고 한 번 실행해요. 앱의 데이터 폴더(앱 기준 Documents)에
   `game`, `saves`, `data`, `media` 폴더가 생겨요.
3. 파일 앱에서 그 `game` 폴더에 **디스크 이미지(.iso) 하나**를 넣고 다시 실행해요. 첫 실행 때 이미지를 풀고 검사해요
   (PC판과 같은 설치기예요). 다 풀리면 이미지는 지워져요. 풀리는 동안 이미지 크기만큼 여유 공간이 더 필요해요.

저장 데이터와 설정은 `saves/`, 로그는 `data/orta.log`에 남아요. 부팅 영상(`boot.mpg`)은 `media/`에 넣으면 돼요.

## 화면과 조작

- 가로 모드 고정, 화면의 실제 해상도(레티나)로 그려요. 60Hz로 돌아요 (게임이 60Hz라 120Hz는 발열만 늘어요).
- **화면에 꽉 차요.** 처음 실행하면 화면비가 **SCREEN**(폰 화면의 실제 비율)으로 잡혀요. 아이폰 18 프로맥스
  (2868×1320, 약 2.17:1)에서는 3D 화면이 가로 전체를 채우고, 옆으로 더 보이게 넓어져요(Hor+, 위아래는 그대로).
  가장자리로 옮겨지는 HUD(게이지, 레이더)는 다이내믹 아일랜드·둥근 모서리의 안전 영역 안에서 멈춰요.
  iPad처럼 4:3에 가까운 화면은 4:3으로 시작해요. RECOMP OPTIONS > ASPECT RATIO에서 4:3 / 16:9 / 16:10 / SCREEN을
  고를 수 있어요 (바꾸면 앱을 다시 열어야 해요).
- **터치**: 왼쪽 절반은 떠 있는 스틱, 오른쪽에 A B X Y, WHITE / BLACK, 위에 LT / RT, 아래에 START / BACK.
  버튼은 안전 영역 안에 그려요.
- **게임패드를 연결하면 터치 버튼이 사라지고**, 패드를 빼면 다시 나타나요. 모든 패드는 1P예요.

## 백그라운드

- 앱이 뒤로 가면(홈 화면, 앱 전환, 제어 센터) 렌더러가 멈춰요. iOS는 백그라운드에서 GPU 작업을 막아서, 그때 그리면
  Vulkan 장치를 잃어요.
- 소리도 멈춰요. LiveContainer에서는 앱이 백그라운드에서도 돌 수 있어서, 안 멈추면 계속 소리가 나요.
  돌아오면 소리 출력을 새로 열어요 (iOS가 예전 출력을 소리 없이 돌려줄 때가 있어서요).
- 발열 상태(thermal state)가 바뀌면 로그에 남아요. 오래 할수록 프레임이 떨어지면 발열 때문인지 볼 수 있어요.

## 코드 구조

- `packaging/ios/`: CMake(앱), `Info.plist`, iOS 전용 코드.
  - `ios_app.m`: SDL을 메인 스레드에서 시작하고, 게임을 16MB 스택의 별도 스레드에서 돌리는 동안 메인 스레드는
    UIKit 런 루프와 SDL 이벤트를 돌려요. 툴킷의 NV2A 스레드가 창을 만들고 이벤트를 읽기 때문이에요.
  - `overlay_ios.m`, `touchpad_ios.c`: 터치 버튼과 가상 게임패드 (안드로이드판 TouchOverlay와 같은 배치).
  - `toolkit/0001-xboxrecomp-ios-runtime.patch`: 툴킷의 iOS 부분. `vm_map`(iOS엔 `mach_vm.h`가 없어요), 실행 권한 없는
    메모리, 샌드박스가 공유 메모리를 막을 때 임시 파일, Darwin arm64 시그널 핸들러(MMIO 트랩), MoltenVK의
    `VK_KHR_portability_subset`, 백그라운드 정지, 창 관련 호출을 메인 스레드로 넘기기, 소리 정지·재개.
- `src/`: iOS 분기(`ORTA_IOS`). 폴더는 Documents에, 로그는 통합 로그에도 남기고, Vulkan 확인은 앱에 들어 있는
  MoltenVK로 해요. RESTART NOW는 앱을 다시 열라고 안내해요 (iOS 앱은 스스로 다시 시작할 수 없어요).
- `tools/build_ios.sh`, `.github/workflows/ios.yml`: 빌드.

## 아직 안 된 것

- 실제 기기 확인 전이에요. 첫 빌드에서 컴파일 오류가 날 수 있어요 (`check` 모드부터 돌려요).
- 폰에서 쓸 일 없는 옵션(창 모드, VSYNC, WINDOW CROP 등)은 아직 메뉴에 남아 있어요.
- 4GB 게스트 메모리 창을 예약해요. LiveContainer의 메모리·주소 공간 권한으로 충분한지 기기에서 확인해야 해요.
