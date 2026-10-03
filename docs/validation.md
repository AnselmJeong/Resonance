# 구현·검증 기록

검증일: 2026-10-02 (Asia/Seoul). 앱 버전: Resonance 0.1.0.

## 현재 상태

문서만 있던 프로젝트에 SwiftPM 기반 네이티브 앱, 별도 코어 모듈, GRDB 데이터베이스, SwiftUI 화면, AVQueuePlayer, 외부 정보 파이프라인, 검증 도구를 구현했습니다. `dist/Resonance.app`을 생성하고 `/Users/anselm/Applications/Resonance.app`에 로컬 설치했습니다. Git 저장소를 초기화했으며 커밋·push는 하지 않았습니다. 기존 PRD와 계획 문서, 예시 음원을 보존했습니다.

**PRD의 실사용 v1 전체 완료는 아닙니다.** 재생 엔진은 AVQueuePlayer를 사용하지만 실제 Hi-Fi와 gapless에 대한 Gate 0 결정은 열려 있습니다. 접근 가능한 예시 음원과 현재 Mac에서 소프트웨어 기능을 구현·검증했으며, 실제 라이브러리와 외부 서비스 계정 검증은 구분합니다.

## 환경

| 항목 | 검증 환경 |
| --- | --- |
| Mac | Apple M2 Max, 메모리 64 GiB |
| OS | macOS 27.2, build 26B5091g |
| 툴체인 | Apple Swift 6.2.3, Command Line Tools, macOS SDK 26.2 |
| 최소 배포 타깃 | macOS 14.0. 이 OS에서의 실제 실행은 미검증 |
| DB | GRDB 7.11.1, SQLite WAL, migration v1 / v2-search-ranking |
| 실제 음원 | 프로젝트의 Alexandre Tharaud/Mémoire, FLAC 27곡 및 Cover.jpg |
| 전체 라이브러리 | `/Volumes/Music1`이 연결되지 않아 미검증 |

## 통과한 검사

| 범위 | 결과와 증거 |
| --- | --- |
| 빌드·패키징 | SwiftPM GUI build 성공. 번들 리소스·앱 아이콘 포함. arm64, Mach-O minos 14.0 확인 |
| 서명 | 개발용 ad-hoc 서명. 배포·설치 번들 모두 `codesign --verify --deep --strict` 통과. Developer ID/notarization 없음 |
| 설치된 앱 | 제한된 `PATH=/usr/bin:/bin`으로 `~/Applications/Resonance.app` 실행. 창·커버·트랙·재생 바를 실제 UI에서 확인 |
| 실제 색인 | 1 앨범, 27 트랙, 1디스크. 1…27 순서, 2번과 10번의 별도 Impromptu 유지. UPC 1200214264086 확인 |
| 불완전 크레디트 | 로컬 작곡자 태그가 있는 3곡만 작곡자로 연결. 나머지는 미확정으로 표시 |
| 실제 디코딩 | AVAudioFile로 27/27 FLAC을 끝까지 읽고 프레임 수 확인. 전곡 24-bit/96 kHz/stereo. 이는 Hi-Fi 청취·전송 품질 검증이 아님 |
| 증분 스캔 | 동일 예시 재스캔에서 27/27 파일 재사용 |
| 원본 보존 | 스캔·디코딩·앱 시험 전후 28개 파일의 정확한 상대 경로와 SHA-256 동일. 원본 파일 내용·이름 변경 없음 |
| 재생 UI | FLAC 재생 중 진행 시간이 증가하고, play/pause·seek·next·곡 종료 후 자동 전환 확인. 인물 페이지를 탐색해도 재생과 큐 유지 |
| 큐 복원 | 설치 앱에서 27개 큐의 5번째 트랙을 57.5초로 seek하고 정상 종료. DB에 `57.5 / index 4 / entries 27` 저장. 재시작 UI 및 Diagnostics.json에서 57.5초·27개 큐·일시 정지 확인. 자동 소리 출력 없음 |
| 출력 UI | 네이티브 AirPlay picker에서 Mac과 외부 출력 후보 2개 목록 확인. 수신기를 선택하거나 재생하지 않음. Core Audio의 시스템 출력 이름·nominal rate를 읽고 원본 형식과 분리 |
| Keychain | 설치된 번들에서 임시 테스트 항목 저장 → 읽기 일치 → 삭제 → 부재 확인 통과. 사용자 API 키를 읽거나 변경하지 않음 |
| 데이터베이스 | 실제 앱 DB `PRAGMA integrity_check=ok`. 마이그레이션 전에 일관된 backup 생성. 백업 DB 재개방·큐·즐겨찾기·무결성 단위 검사 통과 |
| MP3 | 저장한 2초 무음 fixture의 제목·앨범·연주자·앨범 아티스트·작곡자·트랙/디스크 번호·길이 및 전체 네이티브 디코딩 통과 |
| 검색 | 실제 UI의 Memoire → Mémoire 및 관련 트랙 검색 확인. NFC/NFD, 악센트·대소문자, 한글 별칭, 일본어 부분 검색, 사용자 FTS 특수문자, 재스캔 후 별칭, 인물 섹션 필터 검사 통과 |
| 대규모 검색 | 100,000개 합성 음악 검색 문서, 혼합 쿼리 100회, limit 80. warm query p95 18.14 ms, max 20.60 ms. 외장 디스크 스캔·실제 10만 음원 재생 성능을 의미하지 않음 |
| MusicBrainz | 실제 디지털 UPC 검색은 count=0. 해당 UPC 결과가 없는 상태를 확인. 판 UPC 차이·트랙 구조 불일치·수동 확정·해제·재스캔 보존은 fixture로 검증 |
| API 장애 | 401/402/403 즉시 오류·키/본문 비노출, 429 bounded retry, TinyFish 부분 Fetch 실패·빈 원문·malformed JSON, private URL 차단 검사 통과 |
| 설명·예산 | 원문에 없는 quote·없는 source ID 거절, 저장된 설명 재개방, 예산 예약 초과 차단, 캐시 적중 시 제공자 추가 호출·비용 없음, 미설정 원격 모델 요청 차단 검사 통과 |
| 실제 로컬 모델 | 실행 중인 Ollama의 qwen3.8:27b-mlx로 합성 자료만 전달하는 smoke test. JSON 구조·출처 ID·원문 quote 검증 통과. 264 입력 / 789 출력 tokens. 실제 음악 자료·TinyFish 결합 검증과 구분 |

기본 `./script/test.sh`의 17개 정의 중 15개 검사가 실행·통과하며 선택적 benchmark와 실제 모델 smoke는 기본으로 건너뜁니다. 두 선택 검사도 별도로 실행해 통과했습니다. 마지막 DB 검색 필터 변경 후 관련 검색 및 서비스 검사 6개를 다시 실행해 통과했습니다. 무료 로컬 모델 범위를 강화한 뒤 서비스 검사 5개와 최종 빌드도 통과했습니다. 최종 오디오 위치 복원 변경은 설치된 번들의 위 종료·재시작 시나리오로 검증했습니다. 새 소스의 `git diff --check`가 통과했으며 원래 문서의 Markdown 강제 개행 공백은 그대로 보존했습니다.

## 발견하고 수정한 문제

- 현재 환경에 XCTest 모듈이 없었습니다. 설치된 Swift Testing.framework의 경로를 쓰는 테스트 스크립트를 제공했습니다. Command Line Tools의 불완전한 Foundation cross-import overlay에 의존하지 않도록 macOS 테스트의 import를 구성했습니다.
- 긴 SwiftUI 매칭 검토 화면의 type-check 실패를 작은 후보·대응 뷰로 나눠 해결했습니다.
- 재스캔이 승인한 인물 별칭의 검색 문서를 덮어쓰는 경로를 수정하고 회귀 검사를 추가했습니다.
- 큐 변경 중 늦은 next 준비 응답과 중복 seek가 새 상태를 덮어쓰지 않도록 generation 검사를 적용했습니다.
- 실제 로컬 모델은 thinking 과정에서 출력 한도를 소진해 빈 설명을 반환했습니다. Ollama 요청에서 `think=false`와 JSON schema를 사용한 뒤 실제 smoke가 통과했습니다. 오류·빈·불완전 응답은 저장하지 않습니다.
- 재시작 시 준비 중 0초 time observer 값이 복원 위치에 간섭할 수 있었습니다. 준비 중 위치 갱신을 막고 복원 seek 완료를 기다린 뒤 저장하도록 수정했습니다.
- Core Audio CFString 소유권을 SDK 계약에 맞춰 `Unmanaged.takeRetainedValue()`로 처리하고 출력 listener 수명을 별도 객체로 관리했습니다. 최종 빌드에 이 경고가 없습니다.
- localhost 프록시와 Ollama `:cloud` 모델이 무료 로컬 모델로 취급되지 않도록 구분했습니다. 해당 요청에는 키·단가·월 예산을 요구하며 API 주소의 query/fragment에 키를 넣지 않도록 차단합니다.

## 남은 검증과 구현 범위

1. 실제 Hi-Fi의 선택·연결 해제·재연결·seek·sample rate 변경과 30분 이상 청취. 앱별 picker와 시스템 경로 각각 확인. 현재 후보 목록을 성공한 수신기 재생으로 간주하지 않습니다.
2. 연속 tone 및 loopback/수신기 녹음으로 로컬·AirPlay gap을 각각 측정하고 AVQueuePlayer 유지 또는 AVAudioEngine 변경 결정. sample-accurate/gapless/bit-perfect를 보장하지 않습니다.
3. `/Volumes/Music1`의 실제 전체 스캔, 섹션별 20–30개 대표 앨범, 태그 충돌·복잡한 박스 세트·같은 볼륨 재연결·권한 실패. 단순 형제 CD 폴더 자동 묶기는 구현했지만 복잡한 박스 세트의 수동 split/merge 편집기는 아직 없습니다.
4. 실제 MusicBrainz 판/녹음/작품 coverage와 관계 품질, TinyFish 계정의 Search/Fetch smoke, 실제 앨범·인물·작품 자료의 end-to-end 설명 생성. TinyFish 계정 키를 설정하지 않아 실제 Fetch를 호출하지 않았습니다.
5. 설명은 구조·출처 ID·원문 인용을 검증하지만 claim의 의미적 정확성까지 자동 보장하지 않습니다. 원문 대상 일치는 검토 화면의 사용자 확인을 거치며 음악학적 사실 검토가 필요합니다.
6. macOS 14의 실제 실행, VoiceOver·Light mode 전체 사용성, 미디어 키 하드웨어, 출력 손실 때 실제 수신기 동작, 대규모 앨범 이미지·메모리·장시간 재생 부하.
7. 현재 인물은 로컬 임시 ID로 앨범에 묶거나 MusicBrainz ID로 공유합니다. 동명이인 수동 병합·분리, 복잡한 작품 계층 편집, 음원 이동 자동 추적, 초대형 box set 관계 조회 분할은 후속 범위입니다. 관계 화면은 큰 결과를 500개로 제한하며 추가 페이지 탐색은 후속 범위입니다.
8. PDF 본문 검색·OCR, APE 디코딩, 단일 이미지+CUE 논리 트랙, 고급 DSP·다중 존은 v1 또는 현재 구현에 포함하지 않습니다. APE/CUE는 발견·미지원 표시를 합니다.

온라인 기능은 설치 앱에서도 꺼져 있으며 API 키 없이 로컬 탐색·재생을 사용합니다. 최초 생성은 출처 선택과 본문 확인 후 명시적 액션으로 수행합니다. 다음 곡의 유료 생성·전체 라이브러리 일괄 요약은 구현하지 않았습니다. 서버·쉘·파일 수정 도구를 LLM에 제공하지 않습니다.

## 설정 수정 검증 · 2026-10-03

- 폴더별 ‘연결 제거’와 원본 보존을 명시하는 확인창을 추가했습니다. 스캔 취소 완료 후 DB 트랜잭션으로 해당 색인·검색·관계·앨범 수정·설명·큐를 정리하고 나머지 폴더 스캔을 재개합니다. 공유 인물·작품과 사용자 별칭은 보존합니다. 다른 폴더의 앨범이 제거 대상 컬렉션으로 이동되어 있으면 자신의 폴더 컬렉션으로 복귀합니다.
- 전체 설정 저장은 입력된 TinyFish/모델 키도 저장·확인한 뒤 성공할 때만 창을 닫습니다. Keychain 실패를 빈 키로 취급하지 않고 오류를 표시합니다. 저장 상태는 키 내용 복호화 없이 메타데이터로 확인하고 실제 키 읽기·저장은 UI 스레드 밖에서 수행합니다.
- TinyFish/모델 키에 테두리가 있는 입력칸·안내·저장 상태를 추가했습니다. TinyFish 연결 확인은 공개 작곡자 검색으로 Search API 응답 또는 HTTP 오류를 표시합니다. 키 삭제 후 새 키 입력이 가능합니다.
- `./script/test.sh`: 20개 정의 중 18개 실행 통과, benchmark/실제 모델 smoke 2개 기본 건너뜀. 실제 27곡 FLAC 디코딩 포함. 최종 공유 컬렉션/Keychain 변경 후 관련 코어·서비스 10개를 다시 실행해 통과했습니다.
- 신규 회귀 검사 3개: 원본 파일 바이트 보존·다른 루트/공유 관계/검색/큐/재연결 유지, 25곡 처리 후 스캔 취소 완료→제거→DB 재개방에서 색인 재출현 방지, 큐의 현재 항목/재생 위치 보존과 제거 시 초기화.
- `/Users/anselm/Applications/Resonance.app`에 갱신 설치하고 서명 무결성을 확인했습니다. 실제 UI에서 키 입력 후 저장 버튼 활성화, 저장 후 창 닫힘, 스캔 중 저장 후 메인 창에서 2,399곡 처리와 중지 버튼이 유지되는 것을 확인했습니다. 기존 두 음악 폴더는 제거하지 않았고 확인창의 취소 동작만 시험했습니다.
- 설치 앱의 임시 진단 계정으로 키 저장→읽기→삭제→재입력→저장→삭제를 확인했습니다. 입력칸 시험 문구가 TinyFish 항목에 저장되어 발생한 HTTP 401은 실제 사용자 키의 인증 검사로 간주하지 않습니다. 시험 항목은 삭제했습니다. 실제 TinyFish 키로 Search/Fetch의 성공 확인은 남아 있습니다.
- 앱 재시작 전 DB를 `dist/validation/Library-before-settings-fix.sqlite`에 SQLite backup API로 보존했습니다. 실제 DB 무결성 진단은 `ok`이며 원래 연결 폴더·사용자 모델 키를 보존했습니다. 라이브러리 스캔은 사용자가 진행하던 상태에 맞춰 재개했습니다.

## X100 출력 점검 · 2026-10-03

**아래는 시스템 출력 우회를 시험했던 이전 단계의 기록입니다. 그 UI는 이후 철회했으며 현재 구현 상태와 실패 원인·미실행 계획은 [X100 조사 기록](/Volumes/Aquatope/_DEV_/Roon_Alternative/docs/x100-airplay-investigation-2026-10-03.md)에 정리했습니다. 시스템 경로의 청취 확인은 앱 단독 연결 성공이 아닙니다.**

- 사용자는 Aurender X100의 자체 재생과 Apple Music→X100 연결이 정상임을 확인했습니다. USB DAC 내장 앰프의 재생 경로도 정상입니다. Mac 내장 스피커에서 소리가 난다는 설명을 X100 시스템 경로의 청취 확인으로 해석했던 초기 판단은 정정했습니다.
- Mac은 macOS 27.2 build 26B5091g입니다. Ethernet(en0, 1 Gbps)과 Wi-Fi(en1)가 같은 LAN에 연결되어 있으며 기본 경로는 en0입니다. X100은 `192.168.0.11:5000`의 RAOP 수신기로 검색되고 Bonjour TXT는 `am=ShairportSync, fv=4.3.2, ss=16, sr=44100, ch=2`입니다. 같은 장치가 두 인터페이스에 검색되지만 이를 장애 원인으로 단정하지 않습니다. ping 2/2 응답, 평균 약 1.85 ms, nc TCP 5000 연결 성공을 확인했습니다.
- macOS AirPlay 로그는 X100의 제어 응답 200·실시간 오디오 전송을 기록했습니다. 앱 picker로 연결을 요청할 때 `configUpdateReasonEndedFailed`, `Cannot connect error for X100-00432f-USB`, HAL 장치 해제 및 기본 출력의 Mac 복귀가 나타났습니다. AVRoutePickerView에 player를 연결한 경우와 nil인 경우 모두 실패했습니다. 수신기 검색·선택 표시만으로 연결 완료를 주장하지 않습니다.
- 시스템 사운드 설정에서 X100을 선택하자 실제 Core Audio 기본 출력이 X100 / AirPlay / 44.1 kHz로 설정됐습니다. 음소거 꺼짐·출력 볼륨 33%를 확인했습니다. 앱에서 `Dream 2`가 0초→1분49초로 진행했으며, 사용자가 **X100에 연결된 DAC·앰프에서 이 음악이 들린다**고 확인했습니다. 이 결과는 앱 단독 AirPlay 세션 성공이나 30분 안정성·gapless·24/96 전송 성공을 뜻하지 않습니다.
- 실패하는 앱 native picker를 기본 UI에서 제거하고, 출력 버튼이 macOS 사운드 설정을 열도록 변경했습니다. AVPlayer는 시스템 오디오 출력(UID nil)을 따르고 비디오 외부 재생은 사용하지 않습니다. 현재 기기명을 재생 바에 표시하고 시스템 출력 선택이 다른 앱에도 적용됨을 안내합니다. [Apple isExternalPlaybackActive 문서](https://developer.apple.com/documentation/avfoundation/avplayer/isexternalplaybackactive)는 이 속성을 비디오 외부 재생 상태로 정의합니다.
- 모든 기본 출력 변경에 일시 정지하던 처리를 수정했습니다. 가용한 출력 선택과 AirPlay HAL 교체는 재생을 유지합니다. 선택 동작 밖에서 AirPlay 장치가 사라져 다른 출력으로 복귀하거나 출력이 없어지면 일시 정지합니다. 수동 일시 정지한 재생을 출력 선택이 자동으로 재개하지 않습니다. 장치 목록·기본 출력 listener와 주기 갱신으로 transport·UID·가용 상태를 확인합니다.
- 빌드 경고 없이 통과. `./script/test.sh`의 22개 정의 중 20개 실행 통과, 선택 검사 2개 건너뜀. 새 출력 회귀 검사 2개는 정상 장치 선택·같은 수신기 HAL 교체·다른 AirPlay 장치 선택·명시적 Mac 선택의 재생 유지와 비의도적 출력 손실의 일시 정지를 검증합니다. 실제 27곡 FLAC 전체 디코딩도 통과했습니다.
- CPU load 약 2.9, swap 0, 메모리 pressure 정상, 시스템 디스크 여유 약 133 GiB였습니다. 점검 범위에서 자원 부족을 연결 실패 원인으로 볼 증거는 없었습니다.
- Shairport Sync [5.5.2 릴리스](https://github.com/mikebrady/shairport-sync/releases/tag/5.5.2)는 Apple OS 27의 buffered audio 호환성 수정을 포함합니다. 다만 X100 광고는 classic RAOP이고 Apple Music 연결이 정상이라 이 릴리스 문제를 현재 앱 picker 실패의 확정 원인으로 삼지 않습니다. 오렌더의 소프트웨어나 설정은 수정하지 않았습니다.
- 남은 항목: 앱 단독 AirPlay 세션 실패의 정확한 프로토콜 원인, 실제 장치 분리/재연결, 30분 이상 안정성·gapless 측정. 현재 사용 가능한 경로는 Mac의 시스템 AirPlay 출력입니다.
- 최종 설치본 SHA-256: `8631785897a814f8f93d2ab2beec92cc18946d388582f37ff8aa645aff39c706`. `dist`와 설치본 바이너리 일치, `codesign --verify --deep --strict` 통과. 설치 UI에 `현재 출력: X100-00432f-USB` 표시, 출력 버튼→시스템 Sound 화면→X100 선택 유지 확인. 검증 후 재생은 일시 정지 상태로 두었습니다. 사용자가 변경한 출력 볼륨은 유지했습니다. 최종 출력 UI 변경 후 관련 출력 검사 2개를 다시 실행해 통과했습니다.

## 앱 단독 X100 연결 재점검 및 중단 · 2026-10-03

- 시스템 사운드 설정으로 연결하는 임시 UI를 철회하고 AVQueuePlayer에 결합한 native AirPlay picker를 복원했습니다. 기본 출력 표시는 ‘시스템 기본 출력’이며 앱별 AirPlay 연결 성공을 의미하지 않습니다.
- 최소 AppKit 앱에서도 FLAC/AAC의 native 연결이 실패했습니다. 활성 X100 HAL UID 고정은 Mac 기본 출력 복귀 후 장치 소실·item 실패를 막지 못했습니다. 개발 서명과 직접 RTSP OPTIONS 성공 이후에도 picker 오류가 재현됐습니다.
- 독립 pyatv 0.16.1 송신은 ANNOUNCE/SETUP/RECORD/FLUSH의 200 응답 뒤 약 1.3초 만에 끊겼습니다. 실제 청취 성공은 확인하지 못했습니다. ALAC 비교용 pyatv 0.12.1 환경은 준비만 했고 송신하지 않았습니다.
- 최신 복원 후 빌드와 출력 관련 검사 2개가 통과했지만, 앱 단독 X100 연결은 미해결입니다. 현재 설치본과 dist 실행 파일 SHA-256은 `c66c99c0f80ab4174b1da46b07ae843ad2524e6221ccff34563f520b1bc0b64d`로 일치합니다. 위 `863178…`은 철회된 UI 단계의 과거 빌드입니다.
- 사용자의 중단 요청에 따라 진단 프로세스를 종료했습니다. 중단 시 Mac의 일반 출력·사운드 효과 출력은 내장 스피커였고 재생은 일시 정지 상태였습니다. 이후 문서 작성 중 연결 시험을 재개하지 않았습니다.
- 실패 단계, 원인 가설의 한계, 원문 로그, 재개 시 검증 순서는 [X100 조사 기록](/Volumes/Aquatope/_DEV_/Roon_Alternative/docs/x100-airplay-investigation-2026-10-03.md)을 기준으로 합니다.

## X100 직접 AirPlay 출력 · 2026-10-03 16:35

- **해결.** Resonance가 X100에 AirPlay 1(RAOP, ALAC 44.1 kHz/16-bit) 스트림을 직접 보낸다. 시스템 기본 출력은 Mac에 남는다. 사용자가 앰프 음량 35에서 X100 재생, 일시정지·재개, seek, 이전/다음 곡, 자동 곡 넘김을 확인했다.
- 원인: macOS는 앱 단위 AirPlay를 AirPlay 2 수신기에만 허용한다(X100은 AirPlay 1). 이전 직접 송신 시험의 “소리 없음”은 -20~-26 dB의 낮은 AirPlay 음량 때문이었다. 자세한 기록과 구현 위치는 [X100 조사 기록 11절](x100-airplay-investigation-2026-10-03.md)에 있다.
- `./script/test.sh`: 28개 중 26개 실행·통과(선택 2개 건너뜀), 신규 AirPlay 검사 6개 포함. 30분 연속 재생·연결 해제/재연결·설치본 갱신은 남아 있다.
