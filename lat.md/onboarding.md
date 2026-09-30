# 온보딩 도메인 — 면접 재료 수집 위저드 (FeatureOnboarding)

가입 직후 면접 재료를 수집하는 4화면 위저드. 코디네이터가 스텝을 조율하고, 각 화면은 독립 리듀서+뷰(Onboarding<StepName>)로 분리된다. 수집 스텝은 3개(프로그레스 바 3칸), 프리로드는 프로그레스 밖의 종결 화면이다.

이 위저드가 「[PRD] AI 면접 Part 1 — 면접 전 입력 & 포트폴리오 등록」 v3 의 S1~S4 구현체 — PRD↔구현 매핑·잔여 개발 포인트는 [ai-interview](../docs/work/ai-interview.md) §5 가 단일 소스. PRD v3 확정 골자: 재시도·멱등성 전면 제외(실패=status 표시 후 재업로드), 비동기+폴링 확정, 개별 저장 API 없이 세션 생성이 S0~S3 일괄 수집, 직군 6종 화이트리스트, 태블릿 제외.

**직군·연차(구 STEP1·2)는 이 위저드에 없다** — 가입 온보딩(`FeatureAuth` — `AuthOnboardingJob`·`AuthOnboardingExperience`)으로 이관됐고 원본 화면은 삭제됐다(2026-08-02). 위저드는 두 값을 **아예 들고 다니지 않는다**(2026-08-04) — 세션 생성 payload 에서 제거돼 서버가 회원 프로필 스냅샷을 쓰므로([[api#Interview]]) 클라가 쥘 이유가 없다. 이전 판은 `State.init(userName:jobRole:careerYears:)` 로 주입받고 `interviewConfig()` 가 nil 검사까지 했는데, 주입원 배선이 미결이라 **실제 진입은 전부 createSession 을 못 부르고 config 불완전 실패로 떨어졌다** — 검사와 필드를 함께 제거해 그 실패 경로를 없앴다.

## 코디네이터

OnboardingFeature 가 위저드 루트. STEP 1(JD 업로드)을 NavigationStack 루트로 두고, 이후 스텝은 `path`(StackState)로 push 한다. 각 스텝의 delegate 만 매칭해 [[onboarding#수집 데이터]]를 누적하고 다음 스텝으로 전환한다 — 조립은 코디네이터에서만.

순서: JD 업로드 → 포트폴리오 → 대표 프로젝트 → 프리로드. 뒤로가기(backRequested)는 popLast, 닫기(closeRequested)는 delegate(.dismiss), 프리로드 완료(completed)는 delegate(.finished) — dismiss/finished 구분은 AppFeature 가 이탈/완료를 다르게 처리하기 위함. **루트의 «이전으로» 는 앞 스텝이 없어 dismiss 와 같은 신호로 합류한다**(어디로 돌아갈지는 부모가 정한다 — 가입 온보딩이 앞에 있다). 총 스텝 수는 `OnboardingFeature.totalSteps = 3` 단일 소스. @Reducer enum 이 만드는 Path.State 는 Equatable 을 자동 채택하지 않아 명시 채택한다. → [[app]]

## JD 업로드

STEP 1 (선택 — 스킵 가능, 위저드 루트). 탭 «링크 붙여넣기 / 직접 입력하기»는 화면 전환이 아니라 State 의 InputMode. 링크 검증은 **«계속하기»(또는 키보드 리턴) 탭 → 클라이언트 형식 검사 → 통과분만 서버(JDClient.validate)** 2단 — 입력 중 자동 호출은 없다. 성공이면 바로 다음 스텝, 실패면 에러를 띄우고 머문다. 결과는 delegate(.continueRequested(JDSubmission?)) — .link/.text/nil(스킵).

형식 검사는 http/https 스킴+호스트(`isValidLinkFormat`) — 불일치는 서버 왕복 없이 즉시 에러 문구. 에러/성공은 LinkValidation 하위 상태를 필드 변형(`HilitTextField.Status`)으로 그린다. 키패드 밖 터치 시 내림(`dismissesKeyboardOnTap` — SharedDS 공통).

**`.loading` 은 화면에 안 그린다** — 전역 LoadingModal 이 `JDClient.validate` 를 덮으므로 인라인 스피너를 두면 이중 로딩이다([[auth]] 가입 플로우와 같은 방침). 상태 자체는 남아 계속하기 중복 탭 게이트로 쓰인다. 필드 잠금(`.loading` 변형의 `disabled`)도 함께 사라졌는데 안전하다 — 검증 중 타이핑은 `.idle` 로 되돌리며 in-flight 를 취소한다. 100ms 켜기 지연 안에 끝난 검증은 모달조차 안 뜬다(의도 — 그 구간은 «즉시»로 읽힌다. 터치는 그 사이에도 막힌다).

- 성공 후엔 직접입력 탭 비활성. 스킵 시 입력이 있어도 검증·저장 없이 통과(jd=nil).
- 링크 탭 계속하기는 **빈 입력(스킵) 또는 형식 통과 링크**면 활성, 분석 중엔 비활성(중복 호출 방지). 실패 후 재탭이 곧 재시도다. 이미 성공한 링크(뒤로가기 재진입·draft 복원)는 다시 부르지 않고 넘긴다.
- **검증 시점 = 계속하기 탭** (2026-09-30) — 이전엔 입력이 1초 멈추면 자동 검증하고, 성공 뒤 «계속하기» 를 한 번 더 눌러야 했다. 대기는 어차피 전역 로딩이 덮어 미리 부르는 이득이 없었고, 타이핑 중 반쪽 URL 호출·두 번 멈춤만 남아 버튼 한 번으로 모았다. 스텝 전환 트리거는 여전히 사용자 탭 하나다.
- 직접입력 **200~3,000자** 검증 ✅ — 유효 길이만 계속하기 활성(무효 시 카운터·에러 표시, 초과는 클램프 안 함). 빈 입력은 스킵.
- PRD 잔여(TODO): 카피 3곳(헬퍼·에러 fallback) · 링크 본문 <200자 = `CONTENT_TOO_SHORT` 문구 · **링크 검증 1일 5회 제한** 초과 에러. S1 은 캐싱만 — 분석은 세션 생성 시.

## 스텝 공통 골격

수집 스텝 3개가 공유하는 껍데기: 상단 `DashIndicator`(3칸) · 헤더 `TitleBox`(뱃지·마커 타이틀·서브) · 하단 «이전으로 | 계속하기» 2분할 바 · 네비바 X(+선택 스텝은 trailing «건너뛰기»).

바는 DS `ButtonLarge(.bottom, tone: .dark)` 가 그린다(배경·구분선·등폭·비활성 룩 전부 DS 소유) — 화면은 라벨과 액션만 넘긴다. 엣지 스와이프백은 기본 허용 — pop 전에 되물을 게 있는 화면만 차단한다(포트폴리오 업로드 중 `!isUploading`, 프리로드 상시). 스와이프 pop 은 코디네이터에 `popFrom(id:)` 로 도착하며 `backRequested` 와 결과 동일(popLast 뿐)이라 별도 처리 없음 — back 경로에 로직을 넣게 되면 두 입구를 모두 살필 것.

네비바는 DS `.hilitNavigationBar` = **시스템 네비바**라서 [[onboarding#코디네이터]]의 NavigationStack 에 렌더를 의존한다(2026-07-31 커스텀 바 폐기). 스택을 걷어내면 전 스텝의 바가 컴파일 성공 상태로 조용히 사라지므로, 위저드를 cover 단독 화면으로 재구성할 땐 스택을 유지하거나 `.hilitPresentedNavigationBar` 로 바꿔 달 것.

## 포트폴리오 업로드

STEP 2 (필수). PDF 1개(최대 20Mb)를 fileImporter 로 받아 PortfolioClient.register → PROCESSING 이면 3초 간격 status 폴링 → READY/FAILED. idle/uploading/failed/uploaded 를 UploadState 하위 상태로 표현, uploaded 일 때만 계속하기 활성. 파일 제거(X)는 폴링 취소 + 서버 delete.

접수~폴링 구간은 **전역 로딩(LoadingModal)에서 뺀다** — 이 화면이 그동안 진행 카드(`FileUpload.progressing`)를 그리고 그 카드에 취소 X 가 달려 있어, 모달로 덮으면 카드도 취소 동선도 가려진다. 억제는 `PortfolioClient.register`·`.status` 의 liveValue 에 `GlobalLoadingSuppression.run` 으로 건다 (Feature 는 Core 를 모른다) → [[domain.map#네트워킹 인프라]]

- 진행 바는 `UploadState.phaseProgress` — register 접수 전/후 두 단계를 가리키는 **단계 마커**다(0.3 → 0.7). View 의 12초 가짜 램프는 폐기 ✅ — 실측 진행률이 없어 지어내면 실제와 어긋난다. 전이만 이징하고 폴링 구간은 정지하므로, 그 구간의 대기 신호는 상태 문구가 진다. 실제 진행률은 업로드 progress 이벤트나 서버 퍼센트가 생겨야 가능 (TODO) · 폴링 상한 없음 (TODO).
- PRD 검증 분담(클라 선검증 = UX 용 빠른 차단, 최종 판정은 서버 실측): PDF 타입·20MB·**페이지 ≤30**(PDFKit pageCount)·**암호 PDF**(PDFDocument.isEncrypted) 선검증 ✅ — PortfolioFileReader 가 data+pageCount+isEncrypted 반환, register 전 차단. 페이지 수는 PortfolioUpload.pageCount 로 서버에 전달. 글자 수 ≥30 은 서버 전용(Tika) → FAILED_FILE 문구만.
- **실패 문구는 서버 원문** (현행): 4xx 는 `PortfolioError.userMessage`(서버 message), 200 + FAILED_FILE/FAILED_SYSTEM 은 응답 `message` 를 배너에 그대로 싣고, 없을 때만 클라 폴백 문구를 쓴다. 코드별 클라 카피·PRD 문구 정책 미확정이라 임시(코드 TODO 표시).
- **완료 판엔 업로드 진입 판이 없다** ✅ (2026-08-04): `uploaded` 에서 «파일을 업로드해주세요» 진입 판(`FileUpload(.before)`)을 걷고 완료 행(`Completed!`)만 남긴다 — 포폴은 계정당 1개라 올릴 게 없고, 판을 남기면 탭했을 때 갈 곳이 409 뿐이다. 2회차 «기존 포폴로 진행» 도 같은 `uploaded` 라 같이 걸린다. 다시 올리는 길은 X → 삭제 확인 → `idle` 하나뿐이고 그때 판이 돌아온다. 마이페이지 포폴 섹션(`empty` 에서만 진입 판)과 같은 규칙. 시안엔 완료 프레임이 없어 이 규칙이 근거다.
- **X = 삭제 확인 모달**: 파일 행 X(`userTappedRemoveFile`)는 확인 모달만 띄우고(`isDeleteConfirmPresented`), 폴링 취소 + `delete` API 는 «네»(`userTappedDeleteConfirm`)에서만 나간다 — 실수 탭으로 서버 파일이 사라지지 않게. 카드는 마이페이지 삭제 모달(435:8892)과 같은 계열이고 버튼만 «아니요 / 네». **남은 삭제 «1번» 은 하드코딩이다** — 서버 목록 응답이 주는 건 가능 여부·다음 가능 시점(`deleteAvailable`·`nextDeleteAvailableAt`)이고 잔여 횟수가 아니다. 파괴적 동작 바로 앞에서 숫자를 지어내면 오안내라, 횟수를 빼고 두 필드로 표현 가능한 문구(«이번 달 교체 가능» / «N월 N일부터 다시 가능»)로 바꿔야 한다 — 문구 확정 대기 TODO.
- **삭제는 낙관 갱신하지 않는다** ✅ (2026-08-13): «네» 는 판을 즉시 비우지 않고 DELETE 응답을 기다린다 — 성공에만 `idle`, 실패면 첨부 행을 **그대로 남기고** 안내 줄(`InfoField(.error)` 443:9641)에 서버 문구를 싣는다(`State.deleteErrorMessage`, 폴백 `deleteFailureMessage`). 이전 판은 지우고 `try?` 로 결과를 버려서, 실패해도 사용자 눈엔 삭제된 걸로 보이고 서버엔 남아 다음 업로드가 409 로 막혔다(마이페이지 삭제는 처음부터 응답 대기 — 같은 규칙으로 맞췄다). 404 는 «서버에 이미 없음» 이라 성공으로 닫는다. 응답 대기 중엔 `isDeleting` 이 X 재탭을 막고, `uploading` 건이 실패하면 끊어 둔 폴링을 다시 잇는다(안 이으면 `Processing...` 에 멈춘다).
- **2회차 이상 = 기존 포폴 확인 모달** ✅ (2026-08-03): 진입(`view(.onAppear)`)에 `PortfolioClient.list` 로 READY 를 찾으면 «기존에 있는 포트폴리오로 진행할까요?» 모달을 띄우고, 재등록·폴링 없이 곧장 `uploaded` 로 앉힌다. **버튼은 둘(«취소»/«진행할게요»)이지만 액션은 하나다** (2026-08-05 시안 변경) — 포폴은 계정당 1개고 교체는 한 달 1회라 거절해도 갈 곳이 없어, 서버에 READY 가 있으면 어느 버튼이든 그걸 불러오는 것 말고 결과가 없다. 둘 다 `userTappedUseExisting` 으로 모달을 닫고 그 포폴을 완료 판에 앉힌다(바꾸려면 완료 판 X → 삭제 확인 모달이 그 자리). 조회는 **빈 판 진입마다 1회** (2026-08-04 정정 — 이전 판은 «위저드 수명당 1회») — 서버 READY 는 위저드 밖에서 바뀌므로(마이페이지 업로드·삭제, PROCESSING 승격) 수명당 1회로 묶으면 두 번째 진입에서 재사용 대상을 놓치고 register 가 409 로 떨어진다. 코디네이터는 `portfolioStep(upload:)` 에서 `upload == .idle` 일 때만 `checksExisting` 을 켜고(이미 첨부된 판엔 물어볼 게 없다), 중복 호출 방지는 스텝 State 가 `onAppear` 첫 발동에 스스로 끄는 것으로 끝낸다. 첨부된 판으로 pop 복귀하는 경로엔 애초에 조회가 안 켜져서 «기존 포폴로 진행할까요?» 가 다시 뜨지 않는다. 화면에서 삭제(X → «네») 해 빈 판이 돼도 재조회는 하지 않는다 — 방금 지운 걸 다시 쓰라고 묻는 꼴이라. 실패·부재는 조용히 넘긴다(평소의 빈 판 = 1회차 흐름). 판정 키의 근거는 [home-account](../docs/work/home-account.md) §3 «회차 분기 판정 키».
- **모달 표출 자리는 하나** — `.hilitModal` 은 cover 표출이라(#63) 한 화면에 두 번 붙이면 둘째가 조용히 무시된다. 두 모달(기존 포폴 확인·삭제 확인)은 `State.presentedModal` 파생값 하나로 좁혀 띄우고, 우선순위는 기존 포폴 확인이 먼저다 — 진입 직후 뜨고 그 판엔 삭제를 부를 파일 행 X 가 아직 없다.
- **1개 제한은 사전 확인이 주 방어선** — 409 는 확인 모달이 못 막는 틈에만 온다. 진입 조회가 대부분을 걷어내므로 «올리다가 409» 는 평시 경로가 아니고, 남는 창구는 셋이다: ① **PROCESSING 포폴** — 조회 필터가 `status == .ready` 뿐이라 승격 전 포폴은 모달이 안 뜨고, 사용자가 새로 올리면 register 가 409 다(마이페이지에서 올린 직후 온보딩 진입). ② **조회↔등록 경합** — 모달이 안 뜬 사이 다른 기기·마이페이지가 등록. ③ **draft 복원 판** — 아래 항목. 창구가 좁다고 도달 불가는 아니라 복구는 여전히 TODO 다.
- **draft 복원이 서버 검증 없이 완료 판으로 앉는다 🔴**: 진입 조회에는 게이트가 둘이다 — 코디네이터가 `portfolioStep(upload:)` 에서 `upload == .idle` 일 때만 `checksExisting` 을 켜고, 스텝도 `onAppear` 에서 `guard state.checksExisting, case .idle = state.upload` 로 한 번 더 막는다. 그래서 **draft 가 `portfolioId` 를 들고 오면 `.uploaded` 로 복원되고 조회는 아예 안 나간다**. 위저드 안에서만 보면 맞는 최적화지만(이미 첨부된 판엔 물어볼 게 없다), 위저드 밖에서 포폴이 사라진 경우(마이페이지 삭제)엔 죽은 id 가 그대로 프리로드까지 흘러 세션 생성이 깨진다. 복원 id 를 `list` 로 대조해 살아 있을 때만 `.uploaded` 로 앉히거나(부재면 `.idle` + 조회 켜기), [[onboarding#입력 draft]] 의 «포폴 삭제 시 clear» 를 구현해야 닫힌다.
- **409 자동 복구 — 미구현 🔴** (2026-08-02 코드 대조로 정정. 이전 판이 ✅ 로 적어 뒀으나 리듀서엔 없다): register 가 `PORTFOLIO_ALREADY_EXISTS`(409)를 주면 지금은 서버 문구 배너와 함께 failed 로 떨어진다. 설계 의도는 `PortfolioClient.list().first`(계정당 1개라 first 가 곧 그 포폴)로 서버의 기존 포폴을 회수하는 것 — READY 면 uploaded 확정, PROCESSING 이면 폴링 이어받기, FAILED/부재면 삭제 후 재업로드 유도. draft 를 잃었지만(로그아웃·재설치·TTL 만료) 서버 포폴은 남은 경우를 투명 처리하려는 것이고, 원칙은 draft=재개 힌트·서버=진실([[onboarding#프리로드]] JD 복구와 같은 계) — 그쪽은 실제로 구현돼 있다. **폴링 상한**도 미구현.

## 대표 프로젝트

STEP 3 (선택 — 마지막 수집 스텝, 프로그레스 3/3). 300자 자유 입력(DS `HilitTextEditor` — 카운터·클램프를 컴포넌트가 소유) + «나중에 등록해도 괜찮아요!» 툴팁(진입 후 3초 뒤 자동 소멸, onAppear 타이머). 빈 입력·공백만이면 nil(건너뜀)로 올린다.

필드는 InterviewConfig.freeText(10~300자)에 대응. 상한 300자는 입력 클램프, 하한 10자는 continue 로컬 선검증(PRD §7 «클라 선검증=UX 차단, 최종 판정=서버») — 입력이 있고 <10자면 차단+경고, 최종 판정(연관성 등)은 서버. **네비바 «건너뛰기»는 선검증을 타지 않는다** — 입력이 있어도 버리고 nil 로 올린다(빈 입력 경로와 합류).

`inputWarning`(옵셔널) 슬롯 1개로 하한 미달(로컬) 또는 연관성 실패(코디네이터 주입 [[onboarding#프리로드]]) 경고를 노출하고 편집 시 해제한다.

## 프리로드

종결 화면 (프로그레스·뒤로가기 없음, 다크 풀스크린). 코디네이터가 누적 OnboardingData 를 init 으로 주입 — 서버 제출 지점(세션 생성+폴링). 체크리스트 3행은 순차 진행 — 1·2행은 가짜 타이머(1.2s), 3행만 가짜 완료 AND 세션 READY 로 체크. 잠깐 노출 후 채우기 전환 → 완료 화면 → delegate(.completed).

**네비바는 준비 구간 내내 감춘다**(사용자 결정 2026-08-04 — 기다리는 것 말곤 할 게 없는 화면): `leading: .hidden` 만으로는 iOS 26 이 빈 슬롯에 글래스 캡슐을 그려 좌상단에 흐린 원이 남아, `.toolbar(.hidden, for: .navigationBar)` 로 바를 끈다(모디파이어 교체가 아니라 값만 바꿔 애니메이션 유지). X 는 실패 판에서만 살아나고(재시도 없음 → 이탈이 유일한 출구) 그 pop 이 effect 를 자동 취소한다 — 스와이프백도 막혀 있어 **준비 중 이탈 경로는 없다**.

READY 를 받아도 곧장 넘기지 않는다 — `phase` 에 `filling` 을 두어 **그린 사면이 위로 올라와 화면을 덮는 0.9초**(`fillSeconds`)를 끼운다(시안 443:9881 전면 그린). 판을 갈아끼우지 않고 같은 사면의 높이만 키우는 이유는 두 시안이 같은 두 색 그라데이션이어서 — 그라데이션이 판과 함께 늘어나면 색이 튀는 지점이 없다. 글자는 0.3초로 먼저 지고, 완료 문구는 리듀서가 같은 값을 센 뒤(`fillFinished`) 올라온다.

사면은 **콘텐츠의 배경 레이어**다(ZStack 형제 아님). 형제로 두면 ZStack 이 가장 큰 자식에 맞춰 부풀어, 화면보다 큰 사면이 아래로 밀려 오른쪽 위에 검은 삼각형이 남고 글자까지 처졌다(2026-08-04 실기). 배경 레이어는 부모 크기에 영향이 없어 사면을 화면의 1.5배로 넉넉히 넘길 수 있다 — 빗변이 상단 밖으로 완전히 빠져야 오른쪽 위 모서리까지 초록이다.

이 화면이 곧 대기 표시라 **전역 로딩을 얹지 않는다** — `InterviewClient.createSession`·`.sessionStatus` liveValue 에 `GlobalLoadingSuppression.run` 을 건다. AppView 가 Splash 계열 루트를 제외하는 것과 같은 이유(브랜드 대기 화면을 로딩 판이 가린다) → [[domain.map#네트워킹 인프라]] · [[app#Splash 세션 복구]]

세션 생성 연결 = PRD S3.5+S4. → [[interview#Client 계약]]
- ① OnboardingData.interviewConfig() → InterviewClient.createSession + sessionStatus 폴링(3초) ✅. `.domain(interface: .interview)` 의존. PROCESSING→폴링, READY→completed(sessionId), 실패→failed 화면(재시도 없음), config 불완전→failed. onAppear 가드로 중복 시작 방지. CancelID.session 으로 pop 시 취소. createSession effect 는 `startSession(config:)` 로 추출해 최초 시도와 JD 재검증 후 재시도가 공유. **config 불완전 = portfolioId 부재뿐**(2026-08-04) — 위저드 순서상 프리로드 진입이면 항상 채워져 있어 사실상 안 타는 방어선이다. 직군·연차 nil 검사는 제거했다(서버 프로필 스냅샷 — 위 서문).
- ①-JD 검증 만료 자동 복구 ✅ — 서버 JD 검증 캐시는 단명이라 오래된 draft 로 재개하면 createSession 이 `JD_NOT_VALIDATED` 로 거부된다(draft 는 jd 를 영구 유효로 착각). 이때 죽지 않고 저장된 `.link` 를 `JDClient.validate` 로 **1회**(`didRetryJDValidation` 가드) 재검증→valid 면 세션 생성 재시도, invalid/링크 아님이면 failed. 원칙: draft=재개 힌트·서버=진실, 서버 부작용 값은 직전에 서버와 화해. `.domain(interface: .jd)` 의존. → [[api#Interview]]
- ④ READY → delegate(.completed(sessionId)) → 코디네이터 delegate(.finished(sessionId:)) ✅. AppFeature 미배선이라 요약 질문 등 payload 확장은 배선 시.
- ② 연관성 실패 처리 ✅ — `FREETEXT_NOT_RELEVANT` 를 DomainInterview 가 `InterviewError.freeTextNotRelevant` 로 매핑, 프리로드가 delegate(.relevanceCheckFailed) → 코디네이터가 프리로드 popLast + relevanceFailureCount++.
- ③ 재입력 유도 ✅ — 4회 미만은 대표 프로젝트에 경고 문구 주입(편집 시 해제), **4회째**는 코디네이터의 `ConfirmationDialogState` 2선택지([포폴 다시 올리기→STEP2 pop] / [대표 프로젝트 없이 진행→freeText=nil 재분석]).

## 수집 데이터

OnboardingData — 위저드가 스텝을 거치며 채우는 공유 페이로드(Codable — draft 영속용). 코디네이터가 소유하고 각 스텝 delegate 결과를 누적, 프리로드 스텝에 통째로 주입된다.

필드: userName(주입 — 화면 없음) · jd(JDSubmission — .link/.text 상호 배타를 타입 보장, 스킵 nil) · portfolioId · portfolioFileName(draft 복원용) · freeText. JDSubmission 은 OnboardingData.swift 소속 — JD 스텝 delegate 가 올린 값을 코디네이터가 해체 없이 저장한다.

## 입력 draft

PRD §4.4 — 입력을 로컬 draft 로 자동 저장해 **앱 진짜 종료(kill/크래시) 시 재입력 방지**(백그라운드 전환은 프로세스 생존이라 무관). **재개식**: 값 + 위저드 위치 복원.

`OnboardingDraftStore` seam(UserDefaults JSON — (지금은 DomainPortfolio 로 승격한) PortfolioFileReader 처럼 로컬 IO, testValue unimplemented). OnboardingData 는 Codable + portfolioFileName. 코디네이터가 각 스텝 완료마다 `persist`(data·furthestStep=path.count+1·savedAt) 저장, 폐기는 위저드가 아니라 **인터뷰 세션 완료 시 AppFeature 가 clear**(세션 생성 시점에 지우면 면접 도중 킬·이탈에 값이 사라지고 홈의 재사용·[수정하기] 복원도 끊긴다 → [[app]]). onAppear 는 **위저드 수명당 1회**(`didAttemptRestore` 가드) TTL 14일 안 draft 를 복원 — 프리로드(4) 제외 대표 프로젝트(3)까지 되쌓고, JD 는 루트라 `restoring:` init 으로 되살린다. 1회 가드가 필수인 이유: 루트 onAppear 는 뒤로가기로 루트 복귀 때마다 재발동하는데, 가드가 `path.isEmpty` 뿐이면 pop 으로 스택이 빈 순간 draft 를 다시 되쌓아 화면이 앞으로 튄다. 잔여: 포폴 삭제 시 clear.

## 재진입 분기

앱 종료 후 재진입은 [[onboarding#입력 draft]] 가 값·위저드 위치를 복원해 처리한다. draft 에 portfolioId 가 안 들어간 채(업로드는 끝났지만 «계속하기» 전에 죽음) 재진입해도 STEP2 진입 조회가 그 포폴을 찾아 확인 모달로 되살린다 — 대표 프로젝트로 자동 건너뛰지는 않는다.

**반대 방향(draft 엔 id 가 있는데 서버엔 없음)은 아직 안 닫혔다** → [[onboarding#포트폴리오 업로드]] «draft 복원». 포폴 0개(삭제됨) → 다음 진입 시 포폴 스텝 강제 라우팅은 AppFeature 몫 → [[app]].

## 스텝 템플릿

OnboardingPlaceholderStepFeature/View — 스텝 골격(네비바·프로그레스 바·CTA) 템플릿. 실제 스텝이 모두 붙으면서 코디네이터 Path 에서는 빠졌고, 새 스텝 추가 시 복사 출발점으로만 남아 있다 (view/inner/delegate 3분류, delegate 로 continue/back/close 만 통보).

## 코디네이터 연결

홈 「면접 시작」의 [시작하기]·[수정하기] 신호를 AppFeature 가 받아 `fullScreenCover` 로 위저드를 연다 — 홈 탭 위에서만 열리므로 **로그인 이후**라 토큰을 보유한다(온보딩 API 는 인증 필요). dev 전용 임시 진입 버튼은 이 정식 경로가 생기며 제거됐다(2026-08-03). → [[app]]

`OnboardingFeature.State(userName:)`(홈이 쥔 닉네임)로 열고, 직군·연차는 넘길 것이 없다 — 세션 생성이 서버 프로필 스냅샷을 쓴다. 닫는 갈래 둘은 실제로 갈라져 있다(2026-08-04 배선): **delegate(.finished(sessionId:)) → 그 id 로 면접 cover 를 곧장 연다**(`InterviewFeature.State(sessionId:)`, 사용자 결정 2026-07-20 — 홈은 안 태운다, 어차피 면접에 가려진다) · **delegate(.dismiss) → 중도 이탈**(draft 보존 + 홈 `onAppear` 재조회 — STEP2 업로드는 끝났을 수 있어 «이전 정보 재사용» 카드가 옛 값으로 남으면 안 된다). draft 폐기는 이 자리가 아니라 면접 정상 종료다 → [[onboarding#입력 draft]].

코디네이터 onAppear 가 draft 복원을 트리거하므로 OnboardingView 는 루트에 onAppear 를 발신한다. 단 루트 onAppear 는 SwiftUI 특성상 뒤로가기로 루트에 되돌아올 때마다 재발동하므로, 복원은 `didAttemptRestore` 로 1회만 수행한다(재복원=화면 튐 방지). Example 앱은 전체 위저드를 스텁 의존성으로 구동하며 ONBOARDING_START_STEP 환경변수로 특정 스텝부터 시작할 수 있다(draft 는 no-op 스텁). STEP3 이상으로 건너뛸 때는 포폴 픽스처(id·파일명)도 같이 채운다 — 안 채우면 프리로드가 `portfolioId` 부재로 세션 생성 전에 실패 화면으로 떨어진다. → [[app]]

PRD §3.8 부록대로 Part1↔2 경계는 세션 생성 API 계약 — .finished 는 sessionId 만 실어 올리므로 요약 질문 등 payload 확장이 필요하다(서버 정합). 권한(카메라·마이크)은 iOS = 사용 시점 요청이라 온보딩이 아니라 Part 2 진입 직전.
