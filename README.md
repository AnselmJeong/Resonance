# Resonance

PRD.md와 implementation_plan.md를 바탕으로 만든 개인용 네이티브 macOS 음악 앱입니다. 앱 이름은 임시로 Resonance를 사용합니다. 원본 음악은 이동하거나 수정하지 않고 SQLite 색인과 파생 커버만 내부 디스크에 저장합니다.

## 실행

macOS 14 이상, Swift 6 툴체인과 Command Line Tools가 필요합니다. 개발 시 GRDB 7.11.1을 SwiftPM으로 내려받습니다. 배포한 앱에는 Python, Node, Homebrew, ffmpeg가 필요하지 않습니다.

```sh
./script/build_and_run.sh
# 제공된 예시 앨범을 색인하고 실행
./script/build_and_run.sh --verify --sample
# 실행 없이 .app 생성
./script/build_and_run.sh --build
# Release 구성의 앱과 설치용 DMG 생성
./script/build_and_run.sh --dmg
```

생성 앱은 `dist/Resonance.app`입니다. Codex의 Run 버튼도 같은 스크립트를 실행합니다. `--logs`, `--telemetry`, `--debug`로 진단할 수 있습니다. 현재 번들은 로컬 ad-hoc 서명이며 Developer ID 서명과 notarization은 하지 않았습니다.

현재 검증본은 `~/Applications/Resonance.app`에도 설치되어 있습니다. 개발 스크립트는 실행 모드에서 `dist` 번들을 만든 뒤 설치본이 있으면 함께 교체하고 설치본을 실행합니다. `--build`와 `--dmg`는 결과물만 생성하며, DMG는 `dist/Resonance-0.2.0.dmg`에 저장됩니다. `--diagnostics`로 설치 번들을 실행하면 자체 임시 Keychain 항목과 DB·큐·출력 상태를 검사해 저장 폴더의 `Diagnostics.json`에 기록합니다.

처음에는 ‘음악 폴더 추가’로 라이브러리 루트를 선택합니다. `/Volumes/Music1`이 연결되어 있으면 그 폴더를 선택하세요. 직접 하위 폴더가 컬렉션이 되고, ‘모든 앨범’에서 전체를 탐색합니다. 앨범 커버는 상세 화면을 열고, 재생 버튼이 음악을 시작합니다.

## 제공 기능

- 재귀 색인, 변경 파일 재스캔, 스캔 중 탐색·취소, 숨김·백업 폴더 제외, symlink 회피, 외장 볼륨 식별과 재연결. 연결 해제나 스캔 실패로 기존 색인을 삭제하지 않습니다.
- 폴더·내장 커버의 축소 캐시, 앨범 상세, 디스크별 트랙, 부클릿을 기본 PDF 앱으로 열기, 즐겨찾기, 앱 안의 앨범 표시 정보·컬렉션·커버 수정.
- FLAC/MP3 및 Apple 지원 오디오 경로, 앨범 재생, play/pause, previous/next, seek, 볼륨, 다음에 재생·큐 추가·이동·제거, 큐와 마지막 위치 복원, 미디어 키와 Now Playing.
- AVQueuePlayer에 연결한 앱 AirPlay 선택기. 시스템 기본 출력·장치 sample rate는 별도 정보로 표시합니다. X100의 시스템 경로 재생은 진단용으로만 확인했으며, 앱 단독 X100 연결은 아직 실패합니다. 시스템 출력 변경을 해결책으로 제공하지 않습니다. 장시간 안정성·gapless도 추가 검증이 필요합니다.
- 로컬 태그와 확인한 외부 크레디트의 작곡자·연주자·지휘자·편곡자 링크, 작품/녹음 관계, 사용자 승인 별칭, SQLite FTS와 n-gram 기반 한글·일본어 부분 검색, 섹션·역할·형식 필터.
- MusicBrainz 판 후보, UPC·트랙 구조 일치 근거, 디스크·트랙별 검토, 수동 확정·해제. 제목만으로 작곡자를 추정하지 않습니다. 외부 매칭은 원본 태그와 별도로 보존합니다.
- TinyFish Search/Fetch로 자료 선택·원문 읽기·대상 확인 후 설명 생성. 출처 URL·조회일·생성일·AI 표시, 근거 인용 검증, 오프라인 설명 캐시.
- Ollama와 OpenAI 호환 Chat Completions 어댑터, Keychain 키 저장, 일관된 SQLite 백업과 마이그레이션 전 자동 백업.

온라인 기능은 기본으로 꺼져 있습니다. 설정에서 활성화하고 TinyFish 키와 모델을 설정해야 합니다. Ollama는 실행 중인 로컬 서버의 Chat API 주소와 설치한 모델 이름을 입력합니다. OpenAI 호환 API(예: Ollama Cloud `https://ollama.com/v1`)는 HTTPS 주소, API 키, JSON mode 지원 모델을 입력합니다. 이 Mac의 로컬 서버가 아닌 주소에는 API 키가 필요합니다. 앨범·음악가·작품 이야기는 페이지를 열면 자동으로 검색·요약되며, 소셜·동영상·스트리밍 페이지는 출처에서 제외합니다. 원문을 읽지 못하면 검색 snippet만으로 설명을 생성하지 않습니다. 음원과 부클릿을 업로드하지 않습니다.

주요 단축키는 폴더 추가 `⌘⇧O`, 재스캔 `⌘R`, 검색 `⌘F`, 재생/일시 정지 `⌘P`, 이전/다음 `⌘←` / `⌘→`, 큐 `⌘⇧Q`, 감상 정보 `⌘⌥I`입니다.

설정의 각 음악 폴더 옆 ‘연결 제거’는 해당 폴더의 앱 색인·앨범 수정·저장된 설명과 큐 항목을 정리하며 원본 파일은 보존합니다. 스캔 중에도 제거할 수 있습니다. API 키를 새 입력칸에 넣고 ‘설정 저장’을 누르면 Keychain에 저장하고 설정 창을 닫습니다. 개별 키 저장 후 ‘TinyFish 연결 확인’으로 검색 API 인증과 응답을 확인할 수도 있습니다.

## 검증

```sh
./script/test.sh
RESONANCE_BENCHMARK=1 ./script/test.sh --filter SearchBenchmark
# 이미 설치되고 실행 중인 로컬 모델만 사용하는 선택적 smoke test
RESONANCE_LLM_SMOKE=1 RESONANCE_LLM_MODEL='<installed-model>' ./script/test.sh --filter actualLocalProviderSmoke
```

Command Line Tools에서 테스트 프레임워크 경로가 기본 검색 경로에 없을 때도 `script/test.sh`가 제공된 Swift Testing.framework를 찾아 실행합니다. 테스트용 2초 무음 MP3는 ffmpeg로 생성해 저장한 fixture입니다. 테스트 실행 및 앱 동작에 ffmpeg를 요구하지 않습니다. 예시 FLAC은 배포하거나 Git에 추가하지 않으며, 로컬 예시 폴더가 없는 환경에서는 해당 통합 검사를 건너뜁니다.

검증 결과와 PRD 대비 남은 항목은 [검증 기록](docs/validation.md)에 정리합니다. **현재 버전을 PRD의 실사용 v1 전체 완료로 간주하지 않습니다.** 실제 Hi-Fi의 30분 재생·출력 손실·gapless, 실제 전체 컬렉션 규모, 최소 지원 OS, 계정 키를 사용하는 외부 서비스 검증이 남아 있습니다.

X100 앱 단독 AirPlay 연결의 실패 시도·원인 가설·미실행 해결책은 [X100 조사 기록](/Volumes/Aquatope/_DEV_/Roon_Alternative/docs/x100-airplay-investigation-2026-10-03.md)에 남겼습니다. 현재 조사는 사용자 요청으로 중단한 상태이며 연결 문제는 미해결입니다.

## 저장 위치와 복구

`~/Library/Application Support/Resonance/Library.sqlite`에 색인·수정·출처·설명·큐·설정을 저장하고 `Artwork/`에 파생 커버를 둡니다. API 키는 `local.Resonance` 서비스의 macOS Keychain 항목에 저장합니다. 설정의 ‘일관된 DB 백업’은 WAL을 포함하는 SQLite backup API를 사용합니다. 앱을 실행 중일 때 `.sqlite` 파일 하나만 복사하는 방식은 사용하지 마세요.

복구할 때는 앱을 종료하고 기존 DB 및 WAL/SHM을 다른 폴더로 옮겨 보존한 뒤, 백업 DB를 `Library.sqlite`로 복사하고 다시 실행합니다. 원본 음악 폴더에는 쓰기 작업을 하지 않습니다.

## 구조와 공급원 문서

`Sources/ResonanceCore`는 데이터베이스, 메타데이터, 스캔, 검색, 네트워크, 설명 파이프라인입니다. `Sources/Resonance`는 SwiftUI 화면, 앱 상태, AVQueuePlayer와 네이티브 브리지입니다. 인물 이름만 같은 경우 앨범 간 자동 병합하지 않고, MusicBrainz ID로 확정한 인물은 전체 라이브러리 관계를 공유합니다.

[GRDB](https://github.com/groue/GRDB.swift), [Apple AirPlay](https://developer.apple.com/documentation/avfoundation/supporting-airplay-in-your-app), [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API), [TinyFish Search](https://docs.tinyfish.ai/search-api/reference), [TinyFish Fetch](https://docs.tinyfish.ai/api-reference/fetch-and-extract-content-from-urls), [Ollama API](https://github.com/ollama/ollama/blob/main/docs/api.md).
