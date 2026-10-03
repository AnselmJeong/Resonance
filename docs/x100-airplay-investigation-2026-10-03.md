# X100 AirPlay 연결 조사 기록과 인계 계획

작성일: 2026-10-03, Asia/Seoul. 대상: Resonance / Aurender X100 / `X100-00432f-USB`.

**갱신(같은 날 16:30): 해결됨. 11절을 먼저 읽는다.** 아래 1–10절은 해결 전 기록이며, 4.6의 “직접 RAOP 실패” 판단은 11절에서 정정했다.

**(해결 전 상태) 조사 중단, 앱 단독 연결 미해결, 정확한 원인 미확정이었다.** 사용자의 중단 요청 이후 진단 프로세스를 종료했다. 이 문서는 그때까지의 코드·로그·사용자 청취 확인을 정리한 기록이며, 연결 시험을 재개한 결과가 아니다. 아래 해결책은 재개 시 검토할 계획이다.

## 1. 해결해야 하는 문제와 성공 조건

사용자가 원하는 동작은 **Resonance의 음악만 X100에 연결된 DAC·앰프로 보내고, Mac의 일반 출력과 알림은 Mac에 유지하는 것**이다. Mac 전체 기본 출력을 X100으로 바꾸는 것은 연결 가능성을 확인하는 임시 시험이었다. 이를 제품의 해결책으로 제공하면 다른 앱의 소리까지 Hi-Fi로 나갈 수 있으므로 요구사항을 충족하지 않는다.

확인된 결과는 다음과 같다.

| 경로 | 결과와 근거 | 해석 범위 |
| --- | --- | --- |
| X100 자체 음악 재생 → USB → DAC 내장 앰프 | 사용자가 정상 청취 확인 | 앰프·DAC·X100 자체 재생 경로는 동작함 |
| Apple Music → X100 | 사용자가 정상 연결·재생 확인 | 정상 재생의 비교 기준이 있음. 당시 Mac 기본 출력 조건과 내부 전송 방식은 상세 비교하지 못함 |
| Mac 기본 출력 = X100 → Resonance 재생 | 사용자가 `Dream 2`를 X100 쪽에서 청취 확인 | 시스템 출력 경로의 연결 가능성만 확인. 앱 단독 연결의 성공이 아님 |
| Resonance의 앱 AirPlay 선택기 → X100 | macOS의 `Could not connect to “X100-00432f-USB”` 반복 | 사용자 요구를 만족하는 경로는 여전히 실패 |
| 독립 진단 앱의 AirPlay 선택기 → X100 | 동일 실패 | 라이브러리 스캔·설정 화면 없이도 재현 |
| 독립 RAOP 송신 시험 → X100 | 제어 세션 시작 후 약 1.3초 만에 연결 끊김 | 제어 응답과 송신 프레임은 확인했지만 실제 청취 성공은 확인하지 못함 |

출력 후보 목록에 보이는 것, 선택 표시가 생기는 것, 재생 시간이 움직이는 것, RTSP가 `200 OK`를 반환하는 것만으로 실제 연결 성공을 선언하지 않는다. 성공에는 **X100의 실제 청취 확인과 Mac의 다른 출력 유지**가 모두 필요하다.

## 2. AirPlay에서 Mac이 하는 일

현재 Resonance는 로컬·마운트된 폴더의 파일을 Mac의 `AVQueuePlayer`로 재생한다. 이 구조에서 앱 AirPlay를 사용하면 음원 데이터가 Mac을 거쳐 수신기로 전송된다. 이번 독립 RAOP 시험도 Mac에서 파일을 읽고 오디오를 송신하는 방식이었다.

```text
현재 앱의 재생 구조
음원 파일 / Mac에 마운트된 음악 폴더 → Mac의 플레이어 → AirPlay → X100 → USB DAC·앰프

X100 자체 재생 구조
X100이 접근하는 음악 저장소 → X100의 자체 플레이어 → USB DAC·앰프
                         ↑ 앱이 원격 제어한다면 별도의 제어 연동이 필요
```

따라서 “앱 음악만 AirPlay로 보내기”와 “Mac은 리모컨 역할만 하고 X100이 음원을 직접 읽기”는 다른 구현 과제다. 후자를 원한다면 Aurender의 외부 제어·라이브러리 연동 방법을 별도로 확인해야 한다. 공개 제어 API의 존재, 임의 경로의 재생 가능성, Roon/RAAT 지원 여부는 이번 조사에서 확인하지 않았다. Aurender의 [AirPlay 안내](https://ask.aurender.com/hc/en-us/articles/360034322474-AirPlay-and-Aurender-Music-Servers)는 참고 자료이며, 원격 제어 API가 있다는 근거로 사용하지 않는다.

## 3. 조사 당시 환경과 확인된 사실

아래는 시험 당시의 스냅샷이다. 네트워크 주소와 동적 Core Audio UID는 재개 시 달라질 수 있다.

| 항목 | 관찰 |
| --- | --- |
| Mac | Mac Studio, M2 Max, RAM 64 GiB |
| OS / 개발 도구 | macOS 27.2, build `26B5091g`; Swift 6.2.3 / SDK 26.2 |
| 유선 연결 | en0, 1 Gbps, `192.168.0.9`; 기본 경로는 en0 |
| Wi-Fi | en1, `192.168.0.84`; 유선과 같은 LAN |
| X100 | `X100-00432f.local.` → `192.168.0.11:5000` |
| Bonjour | `_raop._tcp` 검색 성공. 조사 중 `_airplay._tcp` 광고는 관찰하지 못함 |
| RAOP 광고 | `am=ShairportSync`, `fv=4.3.2`, `cn=0,1`, `et=0,1`, `ss=16`, `sr=44100`, `ch=2`, `tp=TCP,UDP`, `pw=false` |
| 기본 도달성 | ping 2/2 응답, 평균 약 1.85 ms; `nc`의 TCP 5000 연결 성공 |
| 리소스 | CPU load 약 2.9, swap 0, 메모리 pressure 정상, 시스템 디스크 약 133 GiB 여유 |

이 결과는 X100이 목록에만 남은 유령 장치이거나 LAN 전체가 끊어진 상태라는 설명과 맞지 않는다. 다만 TCP 도달성이 정상이어도 실제 오디오의 UDP 전송·동기화·세션 유지가 정상이라는 보장은 없다.

유선과 Wi-Fi에서 같은 장치가 중복 검색됐지만 이것을 원인으로 입증하지 못했다. `fv=4.3.2`도 광고 값일 뿐 Aurender 내부 코드가 upstream Shairport Sync의 어떤 커밋·패치를 사용하는지 확정하지 못한다. 광고의 16-bit/44.1 kHz와 원본 FLAC의 24-bit/96 kHz를 혼동하지 않는다. 전체 AirPlay 경로의 실제 전송 품질이나 bit-perfect 여부는 측정하지 않았다.

## 4. 시도한 방법, 실패 지점, 알게 된 것

### 4.1 앱의 native AirPlay 선택기

`AVRoutePickerView.player`를 실제 플레이어에 연결한 경우와 player가 nil인 경우를 비교했다. 모두 X100을 검색했지만 연결 요청에서 실패했다. macOS 로그에는 다음이 나타났다.

```text
configUpdateReasonStarted
configUpdateReasonEndedFailed
Cannot connect error for X100-00432f-USB
```

일부 로그에서 제어 응답과 오디오 활동이 보였어도 최종 세션 유지·청취가 확인되지 않았다. `errorString`이 nil인 실패도 있어, 이 로그만으로 거부된 프로토콜 조건을 특정할 수 없었다.

### 4.2 시스템 기본 출력을 X100으로 변경

macOS 사운드 설정에서 X100을 선택하고 Resonance를 재생했다. 실제 기본 출력이 X100 / AirPlay / 44.1 kHz로 잡혔으며, 사용자가 `Dream 2`를 X100에 연결된 앰프에서 들었다고 확인했다.

**이 시험은 연결 가능성을 입증했지만 제품 문제를 해결하지 못했다.** 이후 출력 버튼을 시스템 사운드 설정으로 연결하는 UI를 잠시 적용했다가, 사용자가 다른 앱·알림까지 Hi-Fi로 보내는 것을 원하지 않는다고 지적해 철회했다. macOS의 사운드 효과 출력만 별도로 설정해도 다른 앱의 일반 출력까지 분리되는 것은 아니므로 충분한 해결책이 아니다.

### 4.3 기존 X100 Core Audio UID를 플레이어에 고정

시스템 출력으로 생성된 X100의 활성 HAL 장치 UID를 `AVPlayer.audioOutputDeviceUniqueID`에 지정했다. 시스템 기본 출력을 Mac으로 돌려도 이 플레이어만 X100을 유지할 수 있는지 확인하려는 시험이었다.

- 15:18:10–15:18:20: UID 지정 후 item 상태가 ready, 재생 시간이 증가했다.
- 15:18:21: 시스템 기본 출력을 Mac으로 바꾸자 X100 HAL 장치가 목록에서 사라졌다.
- 이어 item이 failed로 바뀌고 위치가 약 8.027초에서 멈췄다.

**이미 생성된 임시 HAL 장치를 지정하는 것만으로 독립 AirPlay 세션을 유지하지 못했다.** 이 시험에는 별도의 청취 성공 확인이 없다. [Apple의 UID 문서](https://developer.apple.com/documentation/avfoundation/avplayer/audiooutputdeviceuniqueid)는 출력 장치 지정 API를 설명하지만, 지정만으로 새 AirPlay 세션이 생성된다고 설명하지 않는다.

### 4.4 라이브러리 없는 최소 앱, FLAC과 AAC 비교

DB·Keychain·스캔을 사용하지 않는 AppKit 진단 앱을 만들었다. 원본 FLAC과 진단용 AAC 파일을 같은 `AVPlayer`와 native picker로 비교했다. AAC는 별도 파일로 생성했으며 원본을 수정하지 않았다.

기존 27곡의 FLAC 전체 디코딩은 통과했고, 독립 플레이어에서 파일이 ready 상태가 되는 것도 확인했다. UID를 nil로 정리하고 AAC를 새로 로드한 뒤에도 picker 연결이 실패했다. 대표 로그 시각은 AAC 시험 15:19:47.754, 이후 FLAC/native 시험 15:27:39.087이다.

UID 장치 소실 직후의 첫 AAC 로드는 기존 실패 상태의 영향을 받았다. 그 결과는 형식 비교 근거에서 제외했다. 유효한 비교는 UID 정리 후 새 item이 ready·playing이 된 다음의 시도다.

이로써 **FLAC 디코딩 실패만으로 연결 오류를 설명하기 어렵고, 라이브러리 스캔은 오류 재현에 필수 조건이 아니다.** 다만 AAC로 바꿔도 실패한다는 사실이 모든 형식·전송 협상 문제가 배제됐다는 뜻은 아니다.

### 4.5 라우팅 정책·서명·로컬 네트워크 접근 비교

진단 앱의 Info.plist에 `AVInitialRouteSharingPolicy=LongFormAudio`를 임시로 넣었지만 실패가 계속돼 제거했다. 해당 값이 이 macOS 경로에서 실제 적용됐는지는 별도로 입증하지 못했다. 실제 Resonance의 plist에는 반영하지 않았다. macOS에서 지원되지 않는 iOS용 `AVAudioSession` 설정을 복사해 해결했다고 주장하지 않는다. Apple의 [AirPlay 예제](https://developer.apple.com/documentation/avfoundation/supporting-airplay-in-your-app)는 플랫폼 적용 범위를 확인해야 한다.

진단 앱을 Apple Development identity로 서명한 경우도 시험했다. 실제 설치된 Resonance는 기존 ad-hoc 서명이며, 진단 앱의 서명 시험을 제품의 서명 변경으로 혼동하면 안 된다.

Swift `NWConnection`으로 X100에 RTSP `OPTIONS` 요청을 보낼 때 처음에는 `Local network prohibited` / Network is down이 나타났다. 약 3.3초 뒤 연결 상태가 satisfied·ready로 바뀌고 `RTSP/1.0 200 OK`를 받았다. 이 변화의 계기는 기록만으로 확정하지 못했다. 이후 직접 TCP가 정상인 개발 서명 진단 앱에서도 native picker는 다시 실패했다(15:32:21.296).

따라서 **권한·코드 identity가 일부 직접 접속 실패에 관여할 가능성은 있지만, 이를 정리하는 것만으로 native picker 문제가 해결되지는 않았다.** Python CLI의 `No route to host`를 LAN 단절의 확정 증거로 삼아서도 안 된다. Apple의 [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)는 macOS 로컬 네트워크 권한과 코드 identity의 관계를 설명하지만, 이번 X100 오류의 원인을 특정해 주지는 않는다.

### 4.6 native picker를 거치지 않는 직접 RAOP 송신

격리된 Python 환경의 pyatv 0.16.1로 X100에 직접 송신했다. 이는 native 세션 설정 문제와 수신기·송신 프로토콜 호환성을 분리해 보려는 진단이었다. 제품에는 통합하지 않았다. 볼륨 요청은 12%, 스트리밍 시험 상한은 12초로 두었다.

2026-10-03 15:35:57–15:35:59의 로그는 다음 순서다.

| 단계 | 결과 |
| --- | --- |
| TCP 연결 | 성공 |
| `GET /info` | 500. pyatv는 미지원 정보 요청으로 처리하고 계속 진행 |
| `ANNOUNCE` | 200. SDP의 오디오 형식은 `L16/44100/2` |
| `SETUP` | 200. 수신기 control/timing/audio 포트는 6001/6002/6003 |
| 볼륨 `SET_PARAMETER` | 200 |
| `POST /feedback` | 501. pyatv는 이 keep-alive 기능을 시작하지 않고 진행 |
| `RECORD` | 200, `Audio-Latency: 11025` |
| `FLUSH` | 200 |
| 송신 약 1초 뒤 | 44,352 frames를 보냈다고 송신기가 기록 |
| 송신 약 1.3초 뒤 | 제어 연결 종료, 오디오 `Errno 61: Connection refused` |
| 종료 처리 | 끊긴 연결에 TEARDOWN을 시도하면서 `RuntimeError: not connected to remote` |

보존할 핵심 기록은 다음과 같다. 처음 네 줄은 원문 응답의 요약, 뒤쪽은 오류 메시지 발췌다. 시각은 Asia/Seoul이며 전체 로그는 8절에 연결한다.

```text
2026-10-03 15:35:57,641  ANNOUNCE: RTSP/1.0 200 OK
2026-10-03 15:35:57,644  SETUP: RTSP/1.0 200 OK
2026-10-03 15:35:57,892  RECORD: RTSP/1.0 200 OK; Audio-Latency: 11025
2026-10-03 15:35:57,894  FLUSH: RTSP/1.0 200 OK
2026-10-03 15:35:58,893  Sent 44352 frames in 0.998850s
2026-10-03 15:35:59,179  Connection closed
2026-10-03 15:35:59,181  Audio error received: [Errno 61] Connection refused
2026-10-03 15:35:59,189  Connection closed while streaming audio
RuntimeError: not connected to remote
```

**이 시험도 실패했다.** 프레임 수는 송신 측 기록이며 X100의 수신·디코딩·실제 소리를 증명하지 않는다. 500/501 응답 직후에도 처리가 계속됐으므로 그것만으로 연결이 끊긴 원인을 단정하지 않는다. 마지막 Python 예외도 먼저 발생한 연결 소실에 뒤따른 종료 처리 오류이며 최초 원인과 구분한다.

native picker 실패와 직접 RAOP 연결 끊김은 서로 다른 구현에서 관찰한 결과다. 같은 근본 원인이라는 증거는 아직 없다.

### 4.7 ALAC 비교는 준비만 한 단계

pyatv 변경 이력에는 0.13.1에서 ALAC로 감싼 PCM을 raw PCM으로 바꾼 기록이 있다. 이번 0.16.1 시험의 SDP도 L16이었다. 이 차이를 단서로 구버전 0.12.1의 격리 환경을 준비했지만, **중단하기 전 그 환경에서 송신하지 않았다.** 진단 앱 버튼도 0.16.1 환경을 참조한 상태다. [pyatv 변경 이력](https://github.com/postlund/pyatv/blob/master/CHANGES.md)

“ALAC이면 성공한다”, “ALAC도 실패했다”, “ALAC 대응이 완료됐다”는 모두 미확인이다. 구버전 전체를 교체하면 다른 구현 차이도 섞이므로 가능하면 같은 송신 구현에서 형식만 바꿔 비교해야 한다.

## 5. 현재 생각하는 원인과 확실성

**우선 조사할 대상은 앱의 독립 AirPlay 세션 설정과, 이 X100이 받아들이는 송신 조건의 차이다.** 다만 어떤 API 설정·패킷 조건이 잘못됐는지는 특정하지 못했다.

| 가설 | 근거 | 미해결점 / 검증 방법 |
| --- | --- | --- |
| native 경로의 세션 설정이 Apple Music과 다름 | 같은 X100에서 Apple Music은 작동하고 최소 AVPlayer 앱은 실패함 | 정상 예시의 출력 조건·세션·로그 비교가 없음. 공개 macOS API의 설정 조건 확인 필요 |
| 직접 RAOP의 payload·동기화·지연·UDP 조건에 호환성 차이가 있음 | 제어 요청이 통과한 뒤 오디오 송신 직후 끊김 | L16 거부, 동기화 불일치, 포트 문제 등을 구별하지 못함. 수신 로그·정상 통신 비교 필요 |
| 프로세스의 로컬 네트워크 권한·코드 identity가 불안정함 | 직접 TCP의 일시적 prohibited 상태, CLI 접속 실패 관찰 | TCP 성공 후에도 native 실패. 단독 원인으로는 부족. 시험별 identity·권한 상태 고정 필요 |
| macOS 27과 X100 구현 조합에 문제가 있음 | OS와 수신 구현의 버전 차이가 존재함 | Apple Music 정상은 반대 근거. 광고 값만으로 오래된 펌웨어를 원인으로 지목하지 않음 |
| 다른 송신원의 세션 점유·여러 NIC가 영향을 줌 | 비교 시험에서 통제할 후보 조건 | 실제 점유·잘못된 경로의 증거 없음. 필요한 경우 한 조건씩 비교 |

Shairport Sync [5.5.2 릴리스](https://github.com/mikebrady/shairport-sync/releases/tag/5.5.2)에는 Apple OS 27의 buffered audio 관련 수정이 있다. 그러나 이번에 관찰한 classic RAOP와 같은 문제인지 확인하지 못했고, X100 업데이트를 처방할 근거로 삼지 않았다.

현재 증거로 주원인일 가능성이 낮아진 것은 DAC·앰프의 전면 고장, X100에 대한 LAN 도달성의 전면 소실, FLAC 전곡 손상, Mac의 메모리·디스크 부족, 라이브러리 스캔만으로 인한 연결 방해다. 완전히 배제했다는 뜻이 아니라 정상 사례와 독립 재현에 따라 조사 우선순위를 내렸다는 뜻이다.

## 6. 판단·검증에서 잘못한 점

1. **시스템 출력 성공을 제품의 해결처럼 다뤘다.** 도달성 진단이었으며 사용자 요구인 앱 단독 출력을 충족하지 않았다. 시스템 설정으로 연결하는 UI는 철회했다.
2. **Mac 스피커에서 들린다는 설명을 X100의 청취 확인으로 오해했다.** 출력 장소는 사용자의 명시적 확인으로 구별해야 한다.
3. **영상용 상태와 오디오 루트를 구별하는 정리가 필요했다.** `isExternalPlaybackActive`는 비디오 외부 재생 상태이며 오디오 전용 AirPlay 성공 판정에 쓸 수 없다. [Apple 문서](https://developer.apple.com/documentation/avfoundation/avplayer/isexternalplaybackactive)
4. **플레이어 상태·RTSP 응답을 물리적인 재생 성공으로 간주할 수 없다.** 재생 시간·송신 프레임이 증가해도 실제 출음은 별도로 확인해야 한다.
5. **CLI의 No route 오류에서 네트워크 전체 장애를 단정해서는 안 됐다.** nc·Swift 직접 접속·정상 Apple Music과 모순되는 결과를 해석한 뒤 판단해야 한다.
6. **같은 picker를 반복해서 누르는 것만으로 원인을 특정할 수 없다.** 다음 시험은 변경할 한 조건, 기대하는 증거, 실패 시 판단 기준을 먼저 정해야 한다.

## 7. 중단 당시 코드·설치 상태

- Resonance는 `AVQueuePlayer`와 그 player에 결합한 native `AVRoutePickerView`로 돌아왔다. 출력 버튼이 시스템 Sound 설정을 여는 임시 UI는 철회했다.
- picker가 닫힌 것을 접속 성공으로 간주하지 않으며 닫히는 것만으로 재생을 재개하지 않는다.
- `OutputMonitor`는 **시스템 기본 출력**을 관찰한다. 앱 고유 AirPlay의 실제 목적지·연결 상태를 완전히 관찰하는 구현은 아니다. 기본 출력 이름을 앱 연결 대상으로 표시해서는 안 된다.
- 시스템 루트 손실 시 일시 정지 로직과 회귀 검사는 있지만, 앱 단독 연결이 끊겼을 때 Mac으로 소리가 새지 않는지는 미검증이다.
- 직접 RAOP Python 코드·구버전 pyatv·ALAC 비교는 제품에 통합하지 않았다. Apple Development 서명·LongFormAudio 변경도 진단 앱 실험에 한정했다.
- 최신 native picker 복원 후 경고 없는 빌드와 출력 관련 2개 검사가 통과했다. 이전 단계의 전체 검사는 22개 정의 중 20개 실행·성공, 2개 선택 검사 스킵이다. 최신 변경 후 전체 20개를 재실행했다고 기록하지 않는다.
- 최신 빌드와 설치 실행 파일의 SHA-256은 일치한다: `c66c99c0f80ab4174b1da46b07ae843ad2524e6221ccff34563f520b1bc0b64d`. 대상은 `dist/Resonance.app`과 `/Users/anselm/Applications/Resonance.app`이다. 빌드·해시 일치는 X100 연결 성공 증거가 아니다.
- 중단 당시 Mac의 일반 출력·사운드 효과 출력은 내장 스피커로 돌아왔고 재생은 일시 정지 상태였다. 진단 앱과 RAOP 자식 프로세스는 종료했다. 문서 작성 시에도 해당 프로세스가 남아 있지 않음을 확인했다.
- 원본 음원·Aurender 펌웨어·네트워크 설정은 변경하지 않았다. 드라이버 도입이나 macOS 초기화도 하지 않았다.

## 8. 소스와 증거 위치

| 대상 | 경로 / 용도 |
| --- | --- |
| 제품 플레이어 | [PlaybackCoordinator.swift](/Volumes/Aquatope/_DEV_/Roon_Alternative/Sources/Resonance/Playback/PlaybackCoordinator.swift) |
| native picker의 SwiftUI 연결 | [PlaybackViews.swift](/Volumes/Aquatope/_DEV_/Roon_Alternative/Sources/Resonance/Views/PlaybackViews.swift) |
| 시스템 출력 감시 | [OutputMonitor.swift](/Volumes/Aquatope/_DEV_/Roon_Alternative/Sources/Resonance/Playback/OutputMonitor.swift) |
| 루트 변화의 일시 정지 판정 / 검사 | [AudioOutputRoute.swift](/Volumes/Aquatope/_DEV_/Roon_Alternative/Sources/ResonanceCore/Models/AudioOutputRoute.swift), [AudioOutputTests.swift](/Volumes/Aquatope/_DEV_/Roon_Alternative/Tests/ResonanceCoreTests/AudioOutputTests.swift) |
| 최소 AppKit 진단 앱 | [airplay_route_probe.swift](/Volumes/Aquatope/_DEV_/Roon_Alternative/script/airplay_route_probe.swift) |
| 직접 RAOP 진단 | [raop_direct_probe.py](/Volumes/Aquatope/_DEV_/Roon_Alternative/script/raop_direct_probe.py) |
| player·HAL 상태 로그 | [airplay-route-probe.log](/Volumes/Aquatope/_DEV_/Roon_Alternative/dist/validation/airplay-route-probe.log). `+0000`은 UTC이며 본문에서는 9시간을 더한 Asia/Seoul 표기 |
| native 실패 채취 로그 | [native-route-errors.log](/Volumes/Aquatope/_DEV_/Roon_Alternative/dist/validation/native-route-errors.log). 일부 시점의 발췌이며 모든 후속 시험을 포함하는 로그는 아님 |
| 직접 RAOP 제어·송신 로그 | [direct-raop-probe.log](/Volumes/Aquatope/_DEV_/Roon_Alternative/dist/validation/direct-raop-probe.log) |
| 기존 검증·계획 | [validation.md](/Volumes/Aquatope/_DEV_/Roon_Alternative/docs/validation.md), [implementation_plan.md](/Volumes/Aquatope/_DEV_/Roon_Alternative/implementation_plan.md) |

진단 생성물은 `dist/validation/`에 있으며 Git 관리 대상이 아니므로 재빌드·재시험 때 지워지거나 덮어써질 수 있다. 주요 실패 순서는 이 문서에도 남겼다. `raop-venv`는 0.16.1의 실행된 환경, `raop-legacy-venv`는 0.12.1의 준비만 된 환경, `airplay-probe.m4a`는 파생 AAC fixture다.

진단 스크립트는 이번 IP·장치 ID를 고정했으며 일반 사용자용 기능이 아니다. 직접 RAOP 로그에는 LAN 주소·임시 세션 정보가 있으므로 외부 공유 시 필요한 부분을 추출한다. API 키 내용은 문서에 기록하지 않았다.

## 9. 재개할 경우의 해결책과 판단 순서

여기부터는 **미실행 계획**이다. 사용자 중단 지시가 유효한 동안 문서 작성을 이유로 시험을 재개하지 않는다.

### A. 정상 사례를 비교 기준으로 확보

Apple Music이 앱 단독으로 X100을 재생하는 조건을 같은 Mac·같은 수신기·가능하면 같은 로컬 음원에서 기록한다. 일반 출력·사운드 효과 출력을 Mac에 유지하고 실제 X100 출음을 확인한다. 송신원은 하나로 두고 여러 설정을 동시에 바꾸지 않는다.

목적은 정상 루트 확립과 실패의 로그 차이를 얻는 것이다. Apple Music이 작동한다는 사실만으로 같은 네트워크의 native picker도 당연히 작동하리라고 가정하지 않는다.

### B. native macOS의 앱별 루트를 우선 조사

최소 앱과 정상 사례에서 루트 설정 시작·실패 직전 로그를 비교한다. macOS 공개 API·SDK 적용 범위, 수신기의 classic/buffered 기능, 서명·권한의 코드 identity를 확인한다. 새 API 구현 단계에서는 Context7과 Apple의 일차 자료를 참조한다.

유효한 설정 차이를 발견하면 최소 앱에서 한 조건만 바꿔 시험하고, Mac 기본 출력을 유지한 상태의 X100 출음을 확인한다. iOS 전용 설정을 그대로 옮겨 쓰거나 비공개 API·근거 없는 entitlement를 추가한 것을 해결로 간주하지 않는다.

### C. 독립 RAOP는 ALAC 대 PCM 가설 검증부터 진행

가능하면 같은 송신기에서 L16/raw PCM과 ALAC를 비교하고 sample rate·채널·동기화·지연·세션 조건을 맞춘다. 구버전 0.12.1 환경은 보조 비교로 사용하며 버전 전체 변경으로 성공해도 형식만 원인이라고 단정하지 않는다.

송신 직후 다시 끊기면 수신 측에서 얻을 수 있는 로그, UDP 송신·재전송·동기화, 정상 세션 조건을 비교한다. `ANNOUNCE`/`SETUP`/`RECORD` 성공만으로 구현 방향을 확정하지 않는다. 필요한 증거를 얻을 수 없으면 Aurender 지원 자료를 조사하고 같은 실패 조작의 반복을 멈춘다.

### D. 성공한 경로를 확인한 뒤 제품에 통합

native 경로가 성공하면 그것을 우선한다. 직접 RAOP만 성공한다면 Swift 구현 또는 라이브러리·런타임 동봉을 검토한다. 이때 라이선스·의존 버전·네트워크 동의·패키징·연결 끊김 처리·queue·pause·seek·곡 넘김을 평가한다. 먼저 큰 재생 엔진을 교체하지 않는다.

Mac을 음성 경로에서 제외하는 것이 목적이라면 X100 자체 재생을 제어하는 별도 방안의 실현 가능성을 조사한다. 공식적으로 이용할 제어 방법이 확인되지 않으면 그 제약을 명시한다.

### E. 완료 판정 조건

1. Mac 일반 출력·사운드 효과 출력을 내장 스피커에 유지하고 Resonance의 음악만 X100에서 실제로 들린다.
2. 다른 앱의 소리·확인용 시스템 소리가 Hi-Fi로 나가지 않는다.
3. pause·seek·다음 곡·연결 해제·재연결이 작동하며 실패 시 Mac으로 의도치 않은 소리가 나가지 않는다.
4. 30분 이상 재생을 유지하고 UI의 출력·오류 표시와 실제 상태가 일치한다.
5. gapless·전송 형식·bit-perfect는 각각 측정한 범위만 표기한다.

시험마다 가설·변경 조건·실제 출력 장소·로그·결론을 기록한다. 새 증거를 얻지 못하는 동일 실패 반복을 피하고, 미해결이면 미해결 상태로 인계한다.

## 10. 같은 세션의 다른 불편 사항

연결 실패와 앞서 보고된 설정 문제는 구별해서 기록한다.

- 폴더 연결 제거·설정 저장 후 창 닫힘·TinyFish 키 입력 및 삭제 후 재입력은 구현과 관련 검사를 수행했다. 기존 음악 폴더는 삭제하지 않았다. 자세한 결과는 [설정 수정 검증](/Volumes/Aquatope/_DEV_/Roon_Alternative/docs/validation.md)에 있다.
- TinyFish 입력칸 시험용 문자열을 실제 키 저장 항목에 저장해 401이 발생한 실수가 있었다. 시험 값은 삭제했다. 이 401은 사용자의 실제 키가 무효라는 근거가 아니다.
- 실제 TinyFish 키로 Search/Fetch 성공은 미확인이며 입력칸 사용 가능과 외부 서비스 접속 성공을 구별한다.

이번 문서 작성에서는 앱 코드·키·라이브러리 DB·오디오 루트를 변경하지 않았다.

## 11. 해결 기록 · 2026-10-03 16:00–16:35

**Resonance가 X100에 직접 AirPlay 1(RAOP) 스트림을 보내도록 구현했고, 사용자가 X100에 연결된 앰프(음량 35)에서 정상 재생을 확인했다.** Mac 기본 출력은 Mac Studio Speakers로 유지됐다. 일시정지·재개, seek, 이전/다음 곡, 곡 자동 넘김도 사용자가 확인했다. 30분 이상 연속 재생과 연결 해제 후 재연결 시험은 아직 하지 않았다.

### 원인

| 증상 | 원인과 근거 |
| --- | --- |
| 앱의 native picker → X100 실패 | macOS는 개별 플레이어를 AirPlay 1(실시간 `Audio`, `BufferedAudio` 없음) 수신기로 보내지 않는다. 실패한 picker 시도(15:18:54, 15:19:47)에서 AirPlayXPCHelper는 수신기 활성화(`Activating endpoint`)조차 하지 않았다. AirPlay 2인 Samsung Soundbar는 같은 경로에서 활성화됐다. 시스템 출력(15:00:04–15:18:20, 18분 유지)과 Apple Music은 Apple의 시스템 수준 경로를 쓰므로 작동한다. |
| 직접 송신 시 소리가 안 들림 | **AirPlay 음량이 너무 낮았다.** 시험 송신은 -20~-26 dB였고, Shairport Sync의 음량 곡선을 거치면 평소 앰프 음량(35–40)에서는 들리지 않았다. Apple Music도 같은 조건에서 앰프 60 이상이어야 들렸다(사용자 확인). 0 dB(감쇠 없음)로 보내자 앰프 35에서 정상 청취했다. |
| pyatv 0.16.1이 1.3초 만에 끊김 | 원인은 확정하지 못했다. 같은 수신기에서 자체 송신기는 L16·ALAC 모두 15–60초 동안 끊김 없이 유지됐다. |

해결 전 시험(L16, ALAC, RSA/AES 암호화, DACP 광고, uptime 기반 시계, pyatv 0.12.1)은 모두 낮은 음량에서 진행했으므로 “안 들림” 결과로 형식 문제를 판단할 수 없다. 형식 비교는 하지 않았고 제품은 macOS와 같은 ALAC/44.1 kHz/16-bit을 사용한다.

추가로 확인한 것:
- Claude 앱에서 실행한 CLI는 macOS 로컬 네트워크 권한 때문에 LAN TCP 연결이 `No route to host`로 막힌다. `nc`(시스템 바이너리)는 통과한다. LAN 시험은 로컬 네트워크 권한을 받은 앱 번들에서 실행해야 한다.
- Apple Music이 X100을 쓰는 동안 다른 송신은 `RTSP 453`으로 거부된다. 앱은 이를 “다른 기기가 사용 중” 오류로 표시한다.
- 스크린샷의 Apple Music 스피커 선택에 Mac Studio와 X100이 함께 체크되어 있어 Mac에서도 소리가 났다. 해당 선택은 Music 앱의 설정이다.

### 구현

| 구성 | 위치 |
| --- | --- |
| RAOP 형식(ALAC 비압축 프레임, RTP·sync·timing·재전송, SDP, 음량) | `Sources/ResonanceCore/AirPlay/RAOP.swift` |
| RTSP 세션(Bonjour 해석, OPTIONS→ANNOUNCE→SETUP→RECORD→SET_PARAMETER, FLUSH, TEARDOWN), UDP timing 응답·재전송 | `Sources/ResonanceCore/AirPlay/RAOPSession.swift` |
| 디코딩(AVAudioFile → 44.1 kHz/16-bit, 고해상도는 Mastering SRC+dither, 16/44.1은 무변환), Mac 시계 기반 송신, 곡 경계 gapless, pause=FLUSH 후 청취 위치에서 재개 | `Sources/ResonanceCore/AirPlay/AirPlayStreamer.swift` |
| 수신기 검색(`_raop._tcp`, 암호화·비밀번호 없는 44.1/16 수신기만, 이 Mac 제외) | `Sources/Resonance/Playback/AirPlayBrowser.swift` |
| 출력 대상 전환·마지막 수신기 기억(자동 재생하지 않음) | `PlaybackCoordinator.swift` |
| 재생 바 출력 메뉴(실패하던 native picker 대체) | `PlaybackViews.swift`의 `OutputMenu` |

- 로컬 출력은 기존 `AVQueuePlayer`를 그대로 사용한다. AirPlay 수신기를 선택했을 때만 스트리머를 쓴다.
- 앱 음량 100% = AirPlay 0 dB(감쇠 없음). 음량은 앰프에서 조절하는 것을 권장한다.
- 수신기 지연은 macOS와 같은 2초다. 재생 시작·재개·seek 후 약 2초 뒤에 소리가 난다.
- 전송은 16-bit/44.1 kHz다. 24-bit/96 kHz 원본은 변환되며 bit-perfect가 아니다. 16-bit/44.1 kHz 원본은 변환 없이 ALAC로 감싸 전송한다(수신기 이후 경로는 측정하지 않음).
- `Info.plist`에 `NSBonjourServices = _raop._tcp`를 추가했다. 새 빌드(ad-hoc 서명)는 로컬 네트워크 권한을 다시 물을 수 있다.

### 검증

- `./script/test.sh`: 28개 중 26개 실행·통과, 선택 검사 2개 건너뜀. 신규 AirPlay 검사 6개: 수신기 TXT 판정, ALAC 프레임 무손실 왕복, 패킷 배치, 디코더 프레임 수(96 kHz→44.1 kHz, 16/44.1 무변환, seek, mono), localhost 가짜 수신기로 RTSP 순서·0 dB·곡 경계 무음 없음·완료 이벤트·TEARDOWN, pause 시 FLUSH와 청취 위치 유지.
- 실제 X100: 설치 전 `dist/Resonance.app`에서 출력 메뉴 → X100 선택 → 재생. 사용자 청취 확인. 시스템 기본 출력은 Mac Studio Speakers 유지.
- 남은 항목: 30분 이상 연속 재생, 수신기 전원·네트워크 차단 후 오류 표시와 재연결, 실제 측정 기반 gapless 확인, `~/Applications` 설치본 갱신.
