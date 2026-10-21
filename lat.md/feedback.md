# Feedback — 지인 피드백

지인(게스트)이 사용자의 면접 영상을 보고 태도 항목을 4단계 척도로 평가하는 도메인. MVP 범위는 G4(게스트 평가) — 무인증 공유 토큰으로 진입해 영상·지정 항목을 받고 제출한다. 도메인 모듈은 `DomainGuestFeedback`(서버 계약 [[api#Guest Feedback]] + 로컬 임시저장).

사용자측 F4(공유 설정)·R1 지인 섹션은 후속. 스펙: docs/superpowers/specs/2026-07-20-guest-feedback-design.md.

## G4 게스트 평가

FeatureGuestFeedback 의 단일 리듀서 GuestFeedbackFeature. phase(loading→onboarding→starting→evaluating→summary→completed / gateClosed) 하나로 화면을 전환한다 — 선형 플로우라 StackState 를 두지 않는다. 닉네임 입력만 phase 가 아니라 온보딩 위 오버레이 패널(isEnteringNickname 로 구동)다.

GuestFeedbackView 가 phase 로 라우팅하는 화면 순서 — GuestOnboardingView(온보딩)→GuestStartingView(시작 로딩 연출)→GuestEvaluationView(영상+축 평가)→GuestSummaryView(요약)→GuestGateView(completed/gateClosed 공용, 문구만 분기). GuestStartingView 는 별도 화면이 아니라 평가 화면 위 블러 오버레이다 — starting·evaluating 이 한 스위치 케이스(evaluationPhase)로 묶여 GuestEvaluationView 가 계속 살아 있고, starting 동안 그 위에 다크 스크림(블랙 60%+블러, 시안 node 1855:8702)이 얹히며 터치를 차단한다. 시작 연출이 걷히는 조건은 둘이 다 서는 것이다 — 안내 문구 최소 노출 1초(Inner.startingCueElapsed)와 뷰의 영상 준비 종결 보고(View.videoPrepareFinished, State 의 isStartingCueElapsed·isVideoPrepared). 하나만으로 넘기면 준비가 빠를 때 문구가 깜빡이고, 늦을 때 빈 화면에서 평가가 시작된다. evaluating 이 되면 프로토타입 Flow 1(1855:8702→1855:9821)대로 오버레이 페이드아웃 + 축 세그먼트 바·하단 그라디언트 스크림(몰입 모드 전용, 위 투명→아래 블랙 42%) 슬라이드업이 같은 0.35s easeOut 커브로 동시에 진행된다 — 케이스를 가르면 뷰 정체성이 끊겨 이 크로스페이드가 안 되는 게 묶은 이유다. 요약은 최종 시안(node 802:7442)대로 «평가 항목» 헤더 + «영상 다시보기» 버튼과 카드 리스트로 구성되며, 카드 탭(summaryCardTapped)이 해당 축 평가 카드 모드로, 영상 다시보기(rewatchTapped)가 몰입 시청으로 각각 evaluating 에 되돌아간다 — 선형 플로우의 유일한 역방향 간선. 닉네임(GuestNicknameView)은 온보딩 위 커스텀 오버레이 — 딤(블랙 80%) + 상단을 화면 230/812 지점에 고정한 풀블리드 각진 패널 — 로 올라온다. 키보드는 두 계층으로 다룬다: 배경(온보딩+딤)은 키보드 세이프에어리어를 무시해 고정하고, 패널만 시스템 키보드 회피에 참여해 CTA 가 키보드 위로 도킹하며 이름 입력란 상하 Spacer 가 균등 압축된다(수동 키보드 높이 계산 없음). 시스템 `.sheet` 는 키보드가 뜨면 시트 전체가 밀려 높이가 변하고 양옆 여백이 생겨 폐기했다(시안2 는 키보드 시 CTA 만 위로 밀림). "피드백 시작하기" 탭이 표출(isEnteringNickname=true), "다음"(이름 입력 시 활성)이 확정→starting, 딤 탭은 취소(nicknameSheetDismissed)로 온보딩에 머문다.

GuestEvaluationView 는 시트가 아니라 자유전환이다 — 최초 진입은 몰입 모드(풀블리드 영상 + 하단 축 세그먼트만, 시안 «영상 전체 보기»)로 열리고, 축을 탭하면 카드 모드(라운드 영상 카드 + 흰 카드)로 내려온다. 카드 영상의 확대(⛶) 버튼이 몰입 복귀 — AVPlayer 는 뷰 로컬로 두 모드가 공유해 재생이 안 끊긴다. 플레이어는 `AVPlayer(url:)` 로 바로 만들지 않고 AVURLAsset 을 먼저 열어(`load(.isPlayable)`, 5초 마감시한) 성공한 경우에만 만든다 — presigned URL 이 죽었는지 즉시 생성으로는 알 수 없고, AVFoundation 기본 타임아웃(60초)에 맡기면 시작 오버레이가 그만큼 남는다. 열리지 않으면 플레이어 없이 실패 안내(«다시 시도» 포함)가 남고, 어느 결과든 준비 보고가 나가 화면이 멈추지 않는다. 보고는 **준비를 시도할 때마다** 올린다 — 첫 보고만 받으면 «재시도 → 또 실패» 가 버려져 안내(=유일한 재시도 버튼)가 사라진 막다른 화면이 된다(2026-08-14 리뷰 지적). 반대로 플레이어가 이미 살아 있으면 뷰는 아무 보고도 하지 않는다 — 화면 재등장으로 `.task` 가 다시 돌 때 실패로 보고하면 멀쩡한 재생 위에 안내가 덮인다. 재생은 phase==evaluating 일 때만 시작한다(시작 연출 뒤에서 소리부터 새지 않게). 오디오 세션은 .playback 으로 올린다 — 기본 soloAmbient 는 무음 스위치를 따라 음소거되는데 태도 평가에 목소리가 들어간다.

**컨트롤은 리포트 플레이어(`ReportVideoPlayerFeature`)와 같은 동작으로 맞췄다**(사용자 결정 2026-08-13, «면접 영상 다시보기와 똑같이»): 영상 탭 → 딤 65% + 재생 컨트롤 노출 → 3초 뒤 자동 숨김, 진행바는 붙박이(자동 숨김을 안 탄다), 진행바 칸은 초가 아니라 «질문 턴» 단위다. 다만 **배속과 ±10초 건너뛰기는 두지 않는다**(사용자 결정 2026-08-13) — 그래서 좌우 스킵 화살표가 딸린 DS `VideoControl` 대신 중앙 재생/일시정지 판만 게스트 뷰에서 만들고(수치·글리프는 `VideoControl.playPausePlate` 와 동일), 구간 이동 수단은 진행바 칸 탭 하나로 좁혔다. AVKit `VideoPlayer` 를 안 쓰고 `AVPlayerLayer`(GuestVideoSurface)를 직접 얹는 것도 같은 이유다 — 시스템 컨트롤이 배속 메뉴를 달고 온다. 리포트 코드를 가져다 쓰지 못하는 건 Feature→Feature 의존 금지라서고, 화면에 보이는 부분(`VideoControl`·`VideoOverlay`)은 이미 DS 컴포넌트라 양쪽이 같은 물건을 쓴다. 게스트 쪽 차이는 셋뿐 — 대본·하이라이트 시트가 없고, 칸의 출처가 서버 대본이 아니라 `questionBoundaries` 이며(**서버가 아직 안 주는 필드라 실제로는 늘 «영상 전체 한 칸» 으로 폴백한다** — [[api#Guest Feedback]]·`docs/work/guest-feedback-question-boundaries.md`. 필드가 오면 코드 변경 없이 켜진다), 컨트롤 계층은 몰입 모드에만 얹는다(카드 모드는 평가 카드가 화면 주인이라 이동을 아래 경계 칩이 맡는다). 재생 상태는 자식 리듀서 `GuestVideoPlaybackFeature`(부모 State 안 `playback`)가 갖고 AVPlayer 는 뷰 로컬 — 이동 명령은 `seekToken`+`seekTarget` 쌍, 플레이어 재생성은 `reloadToken` 으로 내린다. 경계가 없을 때 서는 «영상 전체 한 칸» 대체 칸은 **탭을 막는다**(`hasQuestionSections`) — 바 아무 데나 눌렀다고 처음으로 되감기면 사고다. 요약의 «영상 다시보기» 는 문구대로 0초부터 다시 튼다. 카드 모드에선 AxisSegmentedBar 로 축을 탭 전환하고, 흰 카드에서 AxisLevelChip(4단계)을 고르고 필요하면 AxisCommentCard 오버레이로 축별 코멘트를 남긴다. 저장된 코멘트는 접힌 행에 그린 액센트 바(4pt)+한 줄 tail 말줄임+«수정» 링크로 표시되고, 비어 있으면 점선 진입 버튼(button-optional)이다 — 어느 상태든 탭이 편집 진입. 코멘트 오버레이는 2계층 키보드 패턴(«[4] 서술형», 묶음 node 2227:5014) — 딤은 화면 고정, 카드+«다음» CTA 아일랜드(px20/py14)만 키보드 위에 도킹하고 등장 즉시 포커스한다. 도킹은 시스템 세이프에어리어 회피가 아니라 키보드 프레임 노티피케이션 실측 — 시스템 회피는 한국어 후보 바(input accessory) 높이를 빼고 계산해 CTA 가 후보 바 뒤에 남는다(닉네임 패널 "수동 계산 없음" 원칙의 유일한 예외). CTA 는 `ButtonLarge(.bottom)`(세이프에어리어 번짐)이 아니라 대칭 py16 모달 변형 `ButtonLarge(.modal)` 이다. 축명·척도 카피는 Figma 확정 짧은 문구(손동작·목소리, 잘 맞춤/꽤 맞춤 류 — GAZE·VOICE 확정, 표정·자세·손동작 척도는 잠정)로 한 줄을 유지한다. 이전 시트 기반 AxisRatingSheet 는 폐기됐다.

척도 칩은 DS `ChoiceChip`(Figma «button-medium» node 2150:7297·2192:5191) 1:1 직사각형(radius 0) — 기본은 흰 필+gray100 테두리, 선택 시 Tone 분기로 1~2단계(좋았어요 쪽)는 positive(cyan) 200/500/800, 3~4단계(아쉬웠어요 쪽)는 error(red) 200/500 필·테두리·텍스트를 쓴다. questionRow 우측엔 축별 저장 인디케이터가 붙는다(node 2555:7558) — State.savingAxisCode(축 코드)로 구동해 없음(미평가)→«저장 중 ...»(스피너, levelSelected 로 세팅)→«저장됨»(그린 체크, 500ms debounce 로컬 draft 저장이 끝나 Inner.draftSaved 가 axisCode 를 nil 로 해제)순으로 표시한다.

지정 항목 전부를 4단계 척도(1=좋았어요~4=아쉬웠어요)로 채워야 제출이 활성화되고, 항목 코멘트(100자)·전반 피드백(300자)은 선택이다. 전반 피드백은 서버 제출 스키마(`{nickname, ratings}`)에 필드가 없어 로컬 draft 전용 휴면 상태다 — 서버 협의 전까지 payload 에 담지 않는다. 마지막 축을 채우는 전이 순간에는 완료 토스트 «모든 평가가 끝났어요!»(Figma BubbleField, node 2555:7543 — 폭 274·b800 직각 박스, CTA 위 10pt)가 뜨고 2초 뒤 자동 해제된다(State.isCompletionToastVisible + Inner.completionToastExpired) — 이미 전부 평가된 뒤 레벨만 바꾸면 다시 뜨지 않는다.

- 제출은 확정 — DS `Modal` 확인(«제출하기»/«취소», `.hilitModal` 오버레이) 1회 후 수정 불가. 성공 시 임시저장 삭제.
- 제출 중 409 는 게이트 전환으로 흡수: closed→비공개 차단, capacityFull→시청 전용 강등, alreadySubmitted→기제출 안내.
- 허용 문자셋(국문·영문·공백·숫자·`! - ~ ? . , / [ ] < >`)과 길이 제한은 binding 단계에서 sanitize.
- 하단 CTA 는 SharedDesignSystem `ButtonLarge(.bottom)`(블랙 풀블리드) 공통 — 온보딩·닉네임·평가·요약 화면에서 재사용한다.

## 진입로와 닫기

실앱 진입은 유니버설 링크 `https://hilit.chottu.link/report?reportId={token}`, 커스텀 스킴 `hilit://feedback/{token}` 은 개발·QA 경로로 존치. 파서 GuestFeedbackDeeplink 가 두 형식에서 토큰을 뽑고 AppFeature 가 루트 밖 fullScreenCover 로 present 한다([[app#Cross-feature Routing]]).

링크 형태는 이 도메인의 계약이라 파서도 Feature 가 소유한다. 닫기는 전 phase **좌상단** X → `delegate(.dismissed)` 가 유일한 탈출구다(2026-08-13 우상단 X 를 뺐다가 2026-08-14 좌상단으로 되살렸고, 같은 날 시안에 `top-bar`(h44·px20)가 들어와 코드 전용 어포던스가 아니게 됐다). 바는 DS `.hilitPresentedNavigationBar` 가 아니라 **오버레이**로 둔다 — 그건 `safeAreaInset` 이라 모든 phase 를 44 내리는데 시안에서 다크(평가) 프레임의 top-bar 는 풀블리드 영상 **위에 절대배치**이기 때문이고, 대신 바를 흐름에 넣은 라이트 화면(온보딩·요약)이 각자 상단 44+16 을 비운다. 바닥이 어두운 phase(시작 연출·평가)는 흰 X + 상단 스크림(`VideoOverlay(.darkClose)` 뒤집기, 리포트 플레이어와 같은 방식)을 얹어 밝은 영상 프레임 위에서도 읽히게 한다. **도착지는 화면이 정하지 않는다** — 로그인돼 있으면 홈, 아니면 소셜 로그인 화면이고 그 판단은 [[app#Cross-feature Routing]] 몫이다.

- 링크 형식의 단일 소스는 `GuestFeedbackShareLink`(DomainFeedbackShareInterface) — **조립(리포트)과 해석(게스트)이 같은 사실을 본다**. 두 Feature 는 서로 의존할 수 없어(D3) 여기가 유일한 공유 지점이고, 갈라지면 만든 링크를 앱이 못 여는 실패가 링크를 받은 지인 쪽에서만 드러난다.
- 값 셋(host·path·쿼리 이름)은 **iOS 단독으로 못 정한다** — 만드는 쪽과 여는 쪽이 플랫폼을 가리지 않아 한쪽만 바꾸면 그 링크가 반대편에서 죽는다. `path` 가 `/report` 인 건 대시보드 슬러그가 생성 후 변경이 안 돼 만들어진 대로 따라간 것이고(`/feedback` 은 404), 쿼리 이름이 `token` 이 아니라 `reportId` 인 것도 Android 와 맞춘 결과다 — 값의 실체는 공유 토큰이지 리포트 id 가 아니다. 배포된 링크는 바꿀 수 없다.
- 파서는 엄격 판정 — 스킴 갈래는 host 일치 + path 세그먼트 정확히 1개, https 갈래는 host·path 일치 + `token` 쿼리 비어있지 않음.
- 설치 상태 진입은 SDK 없이 성립한다 — Associated Domains 만 잡히면 iOS 가 쿼리 원본째 `onOpenURL` 로 준다. 링크 SaaS(ChottuLink)가 맡는 건 **deferred**(미설치 → 스토어 → 첫 실행)와 클릭 어트리뷰션뿐이고, 그 경로는 [[deeplink]] 가 가진다.
- X 는 시안에 없는 코드 전용 상태(플레이스홀더 관례) — 시안 수령 시 교체. 평가 중 닫아도 draft 가 남아 재진입 시 이어하기로 복원된다. X 가 글자를 덮지 않도록 라이트 화면의 본문 시작 높이는 시안 실측을 그대로 쓴다(온보딩 34 = title-box y77 − 상태바 43, 요약 42 → p40) — 마침 X 가 끝나는 높이(위 10 + 글리프 24)와 같다.
- Example 은 dismissed 라우팅을 붙이지 않는다(화면 상태 확인 목적) — X 는 실앱에서만 유효. 실서버 하네스는 dev.hilit.my 를 직접 주입한다.
- 사용자측 공유 UI(F4·R1 지인 섹션)는 여전히 후속 — R1 리포트(PR #71) 머지 뒤 그 화면에서 FeedbackShareClient 로 배선한다.

## 게이트 판정

진입 GET 의 gate 로 화면을 분기한다 — OPEN(평가 진행) / PRIVATE(비공개·무효) / EXPIRED(영상 만료) / FULL(정원 4명 마감, 영상 시청만 가능) / ALREADY_SUBMITTED(이 기기 제출 완료).

gate 는 닫힌 raw-String enum — 서버가 새 게이트 값을 추가하면 디코딩이 실패해 entryLoaded(.failure)→재시도 알럿으로 흐른다(unknown 방어 케이스 없음). FULL 은 submissionOpen=false 로 평가 입력만 막고 시청은 허용한다. Feature 내부 GateReason.unknown 은 엔트리 없이 차단해야 하는 경우(진입 실패의 정원 마감 등) 전용이다.

- 진입 실패의 영구 도메인 에러도 같은 차단 화면으로 매핑한다 — closed→비공개, 기제출→기제출(임시저장 삭제), 정원 마감→일반 차단(엔트리 없이는 시청 전용 불가).

## Client 계약

`DomainGuestFeedback` 의 GuestFeedbackClient(entry·submit)가 Feature 의 유일한 접근 계약 — 상세 명세·에러 매핑 표는 [[api#Guest Feedback]] 이 단일 소스다. 두 메서드 모두 deviceId 를 명시 인자로 받는다(Feature 가 GuestFeedbackLocalStore.deviceID() 를 전달).

무인증 API 라 AuthorizedNetworkClient 가 아닌 NetworkClient 를 쓴다 — [[domain.map#네트워킹 인프라]]. 서버 에러 코드는 Implementation 이 GuestFeedbackError 로 흡수해 Feature 에 코드 문자열이 새지 않는다.

- GuestFeedbackError 케이스: tokenNotFound·shareClosed·capacityFull·alreadySubmitted·invalid(message:)·networkFailure·serverUnavailable·unexpected.
- 사용자 노출 문구(userMessage)는 표현 관심사라 Feature(GuestFeedbackSupport)가 소유한다.
- 응답 모델은 옵셔널 필드(axes·videoUrl·submissionOpen 등) — Feature 어댑터(axisList·videoURL)가 화면 형태로 좁힌다. questionBoundaries 는 현 서버 응답 스키마에서 빠졌다(2026-08-07 스웨거 기준) — 모델은 옵셔널로 유지하고 경계 칩은 값이 오면 그린다.

## 임시저장과 Device-Id

GuestFeedbackLocalStore(`DomainGuestFeedback`)가 게스트 로컬 상태를 담당한다(UserDefaults). Device-Id 는 deviceID() 최초 호출 시 UUID 를 생성해 영속하고, Feature 의 effect 가 client.entry·submit 의 명시 인자로 전달한다 — 역할은 같은 기기 중복 제출 방지 하나뿐(PRD §2-5).

임시저장(이어하기)은 토큰별 draft 로 저장하고 제출 성공 시 지운다.

- draft 쓰기는 latest-wins — 500ms debounce 저장과 즉시 저장(saveDraftNow)이 같은 취소 ID 를 공유해, 대기 중 stale 스냅샷이 뒤늦게 완료돼 최신 쓰기(예: 코멘트 확정)를 덮지 않는다. 즉시 저장도 draftSaved 를 보내 저장 인디케이터를 해제한다.
- 서버 저장 전환(PRD 🔴협의 3)이 확정되면 이 계약 뒤만 교체한다.

## 영상 보관 연장

클라 관점의 보관 사이클 접점 두 곳 — 지인 최초 조회(entry)가 +7일, 첫 제출(submit)이 +30일 연장을 서버에서 유발한다. 클라는 트리거를 호출할 뿐 계산하지 않는다. 만료되면 gate=EXPIRED 로 시청·평가가 차단되고 "보관 기간이 지나 영상이 삭제되었어요" 를 보여준다.
