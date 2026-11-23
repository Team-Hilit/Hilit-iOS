# 홈 & 회원가입·계정 상태 — 작업 문서 (PRD Part 6·7 → 우리 아키텍처 매핑)

> 「[PRD] Part6. 홈화면」 + 「[PRD] Part7. 회원가입·계정 상태 화면 정의」(2026-07-30 수령)를
> 이 레포의 **Tuist TMA + 순수 TCA** 규칙에 녹인 병합 작업 문서. 두 PRD 를 합친 이유: 홈이 앱의 첫 화면이자
> 가입 플로우의 착지점이라 흐름이 한 덩어리다.
> 화면 구성·명명은 2026-07-31 구두 확정(§0 표) — **UI 는 Figma 시안 수령 시 연결**(figma-screen 스킬 경로).
> 절대 규칙: **Feature→Feature 의존 0 · Client 는 Domain 모듈 Interface/Implementation 분리 · cross-feature 조립은 [[app]](AppFeature)에서만.**
> 면접 위저드/세션 매핑은 [ai-interview](ai-interview.md), 리포트는 [ai-interview-report](ai-interview-report.md).

## 0. 화면 인벤토리 → 레이어 매핑 (확정 화면명 — 2026-07-31)

가입·계정 화면은 전부 **`FeatureAuth`** — 기존 Auth 에 붙여 확장하고, 가입 온보딩(`AuthOnboarding*`)은 `Sources/Onboarding/` 하위 폴더로 그룹핑(단일 모듈 유지 — D3, 폴더링만). 홈은 기존 **`FeatureHome`** 확장.

화면 골격(리듀서·전환·mock 수준 뷰)은 2026-07-31 생성 완료 — 아래 «골격 ✅» 는 **UI(Figma)·API 배선만 남았다**는 뜻.

| 화면 (확정명) | PRD 대응 | 소유·구현 | 상태 |
|---|---|---|---|
| `Splash` | SP — 자동 로그인 판정 | FeatureAuth `SplashView`(정적) + `AppFeature.onAppear` 판정 배선 | 골격 ✅ 판정 ✅ |
| `AuthCreateAccount` | A0 로그인 | FeatureAuth — 기존 AuthFeature 를 `AuthCreateAccountFeature` 로 개명(D5 3분류 정리), 코디네이터 `AuthFeature` 신설 | 골격 ✅ / 🔴 신규·기존 분기(S-1)·실패 토스트 |
| `AuthTerms` | A1 약관 동의(5종) | FeatureAuth — 5종 체크·전체 동의·전문 바텀시트(DS `.hilitBottomSheet` — 커스텀 오버레이) 동작 | 골격 ✅ / 🔴 제출 API(S-1)·전문(S-2) |
| `AuthSuspension` | A4 정지(블랙리스트) 안내 | FeatureAuth — 진입은 홈 게이트 `ACCOUNT_SUSPENDED` → cross-feature 제시 (§4) | 골격 ✅ / 🔴 게이트 배선·CS 주소 |
| `AuthOnboardingNaming` | (PRD Part7 밖 — 디자인 확정) 이름 입력 | FeatureAuth/Onboarding — DS `NameField`, 수집만(제출은 연차 CTA 일괄) | 골격 ✅ |
| `AuthOnboardingJob` | Part1 S0a 직군 선택 | FeatureAuth/Onboarding — 면접 위저드 STEP1 **이관**(원본 삭제 완료 2026-08-02) | 골격 ✅ |
| `AuthOnboardingExperience` | Part1 S0b 연차 선택 | FeatureAuth/Onboarding — 면접 위저드 STEP2 **이관**(원본 삭제 완료). CTA 에서 코디네이터가 `updateProfile` 일괄 PATCH | 골격 ✅ |
| `AuthOnboardingRegister` | 등록 완료 (PRD «가입 완료 화면 없음» 을 디자인이 뒤집음) | FeatureAuth/Onboarding — 프로필 PATCH 성공 시에만 push, 완료 후 `delegate(.signedIn)` | 골격 ✅ |
| 홈 — **두 덩어리(홈 3화면 + 면접 시작 3화면)** (§3) | Part6 전체 | FeatureHome — `Sources/Home/`(`HomeFeature.phase`) + `Sources/StartInterview/`(`StartInterviewFeature`, cover present) | 골격 ✅ / 로드 2종 ✅ (프로필·기록 — 포폴 로드는 2026-08-08 분기 폐기로 제거) / held 판정·재개·중단 배선 ✅ 2026-08-08 / 🔴 위젯 UI |
| A2 권한 안내 | Part7 | **Out — AOS 전용.** iOS 는 사용 시점 요청 (Part2 준비 화면 게이트 ✅, [[interview#권한]]) | — |
| A3 재동의 | Part7 | MVP 미도안 — 분기 자리만 예약 | 🟡 |
| 로그아웃·탈퇴 | Part 5 소유 (탈퇴 완료 → `AuthCreateAccount` 복귀만 계약) | 참고 | — |

**기존 FeatureOnboarding 영향** (2026-08-02 반영 완료): 직군·연차 스텝은 **삭제**됐고 면접 위저드는 JD·포폴·대표 프로젝트 3스텝 + 프리로드로 남았다(`totalSteps = 3`, 루트가 JD). 두 값은 위저드가 아예 다루지 않는다(2026-08-04) — 세션 생성 payload 에서 빠져 서버가 회원 프로필 스냅샷을 쓴다. 주입 시절엔 배선 미결로 프리로드가 세션 생성 전에 실패했다.

## 1. 전체 흐름 (iOS — A2 없음)

```
Splash (앱 실행 시 항상 — 자동 로그인 판정)
 ├─ 세션 토큰 유효 ──▶ 홈 직행
 └─ 토큰 없음·무효 ─▶ AuthCreateAccount (카카오/Apple)
      │ 소셜 인증 + login 교환 성공
      ├─ 신규 ─▶ AuthTerms ─▶ AuthOnboardingNaming ─▶ AuthOnboardingJob
      │            │           ─▶ AuthOnboardingExperience ─▶ AuthOnboardingRegister ─▶ 홈
      │            └ 중도 이탈 → 계정 미생성, 재로그인 시 AuthTerms 재진입
      ├─ 기존 · 동의 최신 ─▶ 홈
      └─ 기존 · 동의 구버전 ─▶ A3 재동의 (MVP 미도안 — 자리만)

AuthSuspension — 정지 계정이 면접 시작 시도 시 (게이트 ACCOUNT_SUSPENDED, §4)

홈 (단일 화면 — phase 스위치, §3)
   ┬ 잔여 "N회 남음" (홈 단독 표시 — 마이페이지 미표시)
   ├ 위젯① [면접 연습 시작 | 이어서 진행] ─ 게이트 ─▶ §3 분기표
   ├ 위젯② 면접 기록 (foldable) ─ [레포트 보기] ─▶ 리포트 뷰 (r1/최종)
   └ 위젯③ 마이페이지로 이동 (Part 5)
```

⚠ 가입 온보딩 4화면(Naming~Register)의 순서·필수 여부는 Figma 수령 시 확정 — 위 순서는 구두 브리핑 기준. 이름·직군·연차 제출은 **연차 화면 CTA 에서 일괄 PATCH**로 확정(2026-08-02) — 성공해야 Register 로 넘어간다.

## 2. 회원가입·계정 상태 (Part 7)

### 확정 정책 (클라 영향분)

- 가입 수단: **카카오·Apple 소셜만**, 이메일 직접 가입 없음. 계정당 제공자 1개 고정. 소셜 로그인은 가입·로그인 미구분 — 첫 인증이면 가입 플로우.
- 필수 동의 **5종**(만 14세 / 이용약관 / 개인정보 수집·이용 / 면접 영상·음성 촬영·저장 / 국외 이전). 선택 동의 없음(마케팅 MVP 미수집) — A1 에 5종 외 체크박스 추가 금지.
- **A0 하단은 비운다**(2026-07-29 확정 — 간주 문구·열람 링크 모두 없음, 열람은 A1 [보기] 전담).
- 계정 정지 = **면접 시작만 차단**(게이트 1 `ACCOUNT_SUSPENDED`). 로그인·레포트 열람·마이페이지·탈퇴는 허용 — 정지여도 A0/홈은 정상.
- 휴면 정책 없음. 탈퇴 후 재가입 = 신규와 완전 동일(서버 식별 불가 — "다시 오셨네요" 류 불가).

### Splash (SP)

앱 실행 시 항상. 세션 복구 판정 중 표시 — 토큰 유무 → `refresh` → `pending` 으로 게이트 2단을 통과시켜 목적지(약관·온보딩·홈·로그인)를 정한다. 흐름·실패 정책의 단일 소스는 [launch-routing](launch-routing.md). 판정 불가(네트워크·5xx)면 토큰을 살린 채 이 화면에서 «다시 시도» 를 받는다.

### AuthCreateAccount (A0 로그인)

`AuthCreateAccountFeature`/`View` 로 개명 완료(D5 3분류 정리 — 카카오·Apple 버튼, signIn→login 교환, 취소 조용히 복귀 동작). PRD 로 확정된 추가분:

| 인증 결과 | 이동 | 상태 |
|---|---|---|
| 신규 (서버에 소셜 식별자 없음) | A1 약관 동의 | 🔴 login 응답에 신규/기존·동의 버전 판별 계약 필요 (S-1 연계) |
| 기존 + 동의 최신 | 홈 (`delegate(.signedIn)` — 기존 경로) | ✅ |
| 기존 + 동의 구버전 | A3 재동의 (MVP: 자리만) | 🟡 |
| 사용자 취소 | A0 유지, 안내 없음 | ✅ (`AuthError.cancelled`) |
| SDK·네트워크 오류 | **토스트** "로그인에 실패했어요. 다시 시도해주세요" + A0 유지 | 🔴 현재 alert — 토스트로 교체 |

### AuthTerms (A1 약관 동의)

진입: 첫 소셜 인증 직후 1회. `FeatureAuth` 내부 화면 — 코디네이터 `AuthFeature` 의 `Path`(StackState)로 push (도메인 내부 내비). 골격 구현 완료([[auth#가입 플로우]]).

- 구성: 제목 «서비스 이용을 위해 동의가 필요해요» / [전체 동의] / 필수 5종 체크 / [보기] = **전문 바텀시트 — DS `.hilitBottomSheet` ✅ 사용**(커스텀 오버레이 — 시안 높이 662/812 로 열리고 그래버를 끌어 전체 높이까지, 아래로 끌기·딤 탭 닫기. 판 색·본문만 호출부) / [동의하고 시작하기] — **5종 모두 체크 시에만 활성**, 일부 체크 시 비활성(별도 경고 없음).
- 제출 = 서버가 **계정 생성 확정 + 무료 3회 부여 + 동의 이력(항목·버전·일시) 저장** — 이용권 D3(부여 시점) 이 이 정의로 자동 확정. API 는 `DomainAuth` 확장 🔴 (S-1: 인증~동의 사이 임시 토큰 상태 서버 협의).
- 제출 성공(iOS) → **가입 온보딩(AuthOnboardingNaming~)으로 진행** (PRD 는 «홈 직행»이었으나 디자인이 온보딩 4화면 경유로 확정. A2 없음 — 권한은 면접 시작 시점). 제출 실패(네트워크) → 토스트 + 화면 유지 + **체크 상태 보존**.
- 중도 이탈(뒤로가기·종료) → 계정 미생성. 재로그인 시 AuthTerms 재진입 — 클라 저장 없음, 서버 판정 수신만.
- 국외 이전 전문은 벤더 답변 대기(S-2) — 화면 뼈대·나머지 4종 전문 먼저.

### 가입 온보딩 — AuthOnboarding* (FeatureAuth/Sources/Onboarding/)

AuthTerms 제출 후 이어지는 4화면. AuthFeature 도메인 내부 내비(자체 `Path`/`StackState`) — cross-feature 아님.

| 화면 | 내용 | 구현 재료 |
|---|---|---|
| `AuthOnboardingNaming` | 이름 입력 | 수집만(이름 한글·영문 최대 5자) — 제출은 연차 CTA 의 일괄 PATCH |
| `AuthOnboardingJob` | 직군 선택 | 면접 위저드 STEP1(`JobClient.jobs` 칩) 이관 — 원본 삭제 완료 |
| `AuthOnboardingExperience` | 연차 선택 | 면접 위저드 STEP2(문장형 휠 0~10년) 이관 — 원본 삭제 완료 + CTA 에서 `UserClient.updateProfile`(이름·직군·연차 일괄 PATCH) — [[api#User]] |
| `AuthOnboardingRegister` | 등록 완료 | 신규 — PATCH 성공 시에만 진입, 완료 후 홈 (`delegate` → AppFeature) |

- 이름·직군·연차 제출은 `UserClient.updateProfile` 일괄 ✅ — 연차 화면 CTA 시점, 성공해야 Register(2026-08-02 확정). 실패는 그 화면에 머물러 재탭 재시도.
- 이관 완료 — 면접 위저드([[onboarding]])는 S0 두 스텝을 잃고 JD 부터 시작한다. 두 값은 서버 프로필 스냅샷이 쓰므로 위저드로 주입하지 않는다(2026-08-04).

### A3 재동의 — MVP 미도안 (서버만 고려)

화면은 안 그린다(디자인 협의 확정). 클라는 **분기 자리만 예약**: ① login 응답 «동의 구버전» 판정 ② 면접 시작 게이트 3 `CONSENT_VERSION_STALE` 폴백. 확정 구성(요약 없음 — 바뀐 항목 체크 + 전문 보기 + 동의/나중에)·«나중에 = 면접 시작만 차단» 은 첫 개정 시점 구현.

### AuthSuspension (A4 이용 제한·정지 안내)

진입: 면접 시작(위젯①)에서 게이트 1 `ACCOUNT_SUSPENDED` 수신 시 — **면접 시작 경로에만** 나타난다. 화면은 `FeatureAuth` 소속(블랙리스트 사용자 제한) — 발원지가 홈이므로 **cross-feature**: Home `delegate` → AppFeature 가 제시(§4). 전면/모달 여부는 디자인 확정 대기.

- 구성: 제목 «면접 이용이 제한되었어요» / 사유 «비정상적인 이용 패턴이 반복 확인되어 면접 시작이 제한되었어요» (**내부 용어 노출 금지** — NETWORK_DISCONNECT 등) / [메일 보내기](mailto CS) / [홈으로 돌아가기].
- 정지 검토·수동 정지/해제는 운영 소관 — 클라 로직 없음.

## 3. 홈 (Part 6) — 단일 화면 + phase

**화면 4종이 아니라 화면 1개** — Figma 프레임 4종(`HomeDefault`·`HomeReport`·`HomeStartInterview`·`HomeDuringInterview`)은 같은 화면의 상태 변형이다. `GuestFeedbackFeature` 패턴 채택: `State.phase` enum 하나로 상태를 관리하고 뷰가 phase 스위치로 서브뷰를 연결한다(→ `FeatureGuestFeedback/Sources/GuestFeedbackFeature.swift`).

**구현 시 수정 (2026-08-04)** — 뷰는 phase 별로 쪼개지 않는다: 시안 `HomeDefault`·`HomeReport` 가 겹 구성이 같아 씬(`HomeView`) + 하단 판(`HomeReportSheet`) 둘로 합쳤고, 판 안 내용만 빈 상태 ↔ 목록으로 갈린다. `State.phase` 는 그대로다(판 내용·인사말 변형을 정한다).

**구현 시 수정 (2026-07-31)** — 시안을 받고 두 덩어리로 쪼갰다: «홈»(`HomeDefault` + `HomeReport` 2변형 = `State.phase`)과 «면접 시작»(시안 3장 = `StartInterviewFeature`, 홈 위로 cover present). `HomeDuringInterview` 는 **MVP 제외** — 화면·phase 케이스 모두 삭제(아래 표·`Phase` 스케치의 During 행은 결정 기록으로 남긴다).

| Figma 프레임 | 상태 의미 (구두 브리핑 — Figma 수령 시 확정) |
|---|---|
| `HomeDefault` | 기본 상태 |
| `HomeReport` | 면접 기록(레포트) 표시 상태 — 구현은 «오랜만이에요 OO님!» 인사말 표시 여부 2변형(`returning`/`recent`) |
| `HomeStartInterview` | 시작 CTA 변형 — 처음 / 진행 중 / 무료 횟수 모두 사용 («등록 포폴 있음» 은 2026-08-08 폐기). **phase 아니라 present** (홈 위 전체화면 cover — 홈 스택 push 아님) |
| `HomeDuringInterview` | 진행 중 면접 있음 — 2026-07-31 MVP 제외였다가 **2026-08-07 복귀**. phase 가 아니라 «면접 시작» 겹의 네 번째 변형이다(아래 위젯① 2026-08-07 배선) |

### 회차 분기 판정 키 (2026-08-03 확정 → **2026-08-08 폐기**)

> ⚠️ **폐기** — 포폴 여부를 홈에서 판정하지 않기로 했다(제품 결정 2026-08-08). `hasPortfolio` 변형·[수정하기]·홈의 포폴 로드가 함께 삭제됐고 2회차도 `first` 와 같은 위저드 경로를 탄다(draft 복원이 메운다). 아래는 결정 기록. 위저드 STEP2 의 «기존 포폴로 진행할까요?» 모달은 온보딩 소유라 그대로 산다.

**«2회차 이상» = READY 포트폴리오 보유.** 서버에 면접 이력 필드를 추가하지 않는다 — 이 분기가 실제로 묻는 건 «불러올 포폴이 있나» 이고, 포폴은 계정당 1개([ai-interview](ai-interview.md) §3 Portfolio)라 `PortfolioClient.list` 에 READY 가 있으면 그게 곧 재사용 대상이다. 교체가 한 달 1회로 묶여([mypage](../../lat.md/mypage.md)) 보유자는 새로 올리지도 못하므로, 이들이 가야 할 자리가 «이전과 동일한 정보로» 시안이다.

**2회차도 위저드를 똑같이 탄다** — 갈리는 건 STEP2 뿐이다. 진입 시 READY 포폴이 있으면 «기존에 있는 포트폴리오로 진행할까요?» 확인 모달을 띄우고 «예» 로 완료 판(업로드 끝난 UI)으로 앉힌다([onboarding](../../lat.md/onboarding.md) §포트폴리오 업로드). 없으면 기존 흐름 그대로.

우선순위는 잔여 0(`exhausted`)이 먼저고, 그다음 포폴 유무로 `first`/`hasPortfolio` 를 가른다(`HomeFeature.startVariant`). 포폴을 지운 사용자는 다시 `first` 로 떨어지는데 이게 맞다 — 올릴 게 없으면 S2 부터다(§2 표 «포폴 0개 → S2 강제 라우팅»).

구성(위→아래): **잔여 "N회 남음" → 위젯① 면접 연습 진행(주 CTA) → 위젯② 면접 기록 → 위젯③ 마이페이지**. 위계: 핵심 행동(연습 시작) 최대, 동기(기록·잔여) 곁에, 관리(마이페이지)는 진입점만.

«위젯» = 홈 안의 카드형 기능 블록(OS 위젯 아님). 보관함 탭 폐기·스트릭·알림 배너·페이월은 MVP Out.

### 위젯 ① 면접 연습 진행

기본 [면접 연습 시작], held 세션 존재 시 **[이어서 진행]** 으로 전환(숨기면 슬롯 잠김 혼란 — 같은 `session_id` 복귀 확정). 탭 시 이용권 게이트(`checkStartEligibility` — 이용권 PRD 7장 계약 재사용: 7.2 사전확인 선택·7.3 원자적 시작·Idempotency-Key. **홈은 새 계약을 만들지 않는다**):

| 게이트 결과 | 행선지 | 조립 |
|---|---|---|
| 통과 | 온보딩 위저드 S1~ (직군·연차는 서버 프로필 스냅샷 — 클라 미전송) → 세션 생성 → 면접 | cross-feature — 기존 dev 버튼 경로의 정식화 |
| held 세션 | [이어서 진행] → 같은 session_id 로 Part 2 복귀 (`InterviewFeature.State(sessionId:)` — [ai-interview](ai-interview.md) 작업 D 와 합류) | cross-feature |
| `NO_REMAINING` | «무료 횟수를 모두 사용했어요» 안내 (MVP 후 페이월 자리) | 홈 내부 |
| `PORTFOLIO_NOT_READY` | 포폴 등록(S2) 라우팅 — 교체 소진 시 «다음 달 1일부터 업로드 가능» 병기 | cross-feature (S2 강제 라우팅 — [ai-interview](ai-interview.md) §2 표와 동일 메커니즘) |
| `CONSENT_*` | 동의 플로우 (A3 자리 — §2) | 예약 |
| `ACCOUNT_SUSPENDED` | `AuthSuspension` 정지 안내 (§2) | cross-feature — AppFeature 제시 |
| 기타 (`RATE_LIMITED` 등) | 각 안내 | 홈 내부 |

**추가 (2026-08-07 배선) — «진행 중 면접» 화면이 들어왔다.** 시안 [443:5890](https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=443-5890)(진행 중 — 카드 «면접 상태 · N개의 질문이 남았어요», CTA [처음부터 시작 | 이어서 진행])·[443:5873](https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=443-5873)(처음부터 확인 — 안내줄 «이용권이 하나 차감됩니다.», CTA [뒤로가기 | 처음부터 시작])를 «면접 시작» 겹의 **네 번째 변형** `Variant.inProgress(remainingQuestionCount:)` + State 안 한 단계(`isConfirmingRestart`)로 넣었다. 확인을 별도 화면으로 두지 않은 건 배경·내비바가 그대로고 갈리는 게 인사말·카드·CTA 셋뿐이라서다(띄우면 커튼·X 가 두 겹). 나가는 신호는 `interviewResumeRequested`·`interviewRestartRequested` 둘이었고 당시 AppFeature 는 `.none` + TODO 였다(아래 08-08 배선으로 해소).

**추가 (2026-08-08 배선) — held 판정·재개·중단이 실배선됐다.** 서버에 진행중 세션 목록 API 가 없어(레포트 목록은 진행중 제외) **로컬 보관**을 채택했다: `HeldSessionStore`(DomainInterview, UserDefaults — `sessionId` + 녹화 길이 `recordedSeconds`)를 세션 생성 시 저장(0초)·면접 완료 시 삭제·이탈 시 보존하고, 홈 `onAppear` 가 `load()` 동기 읽기로 `startVariant` 를 가른다 — **held 최우선** → 잔여 0 → 처음. 카드 «N개의 질문이 남았어요» 는 서버 재료가 없어 **rule-base 환산**: 남은 시간 = 8분 − 녹화 길이, 3분 미만 1 / 3~5분 2 / 5~7분 3 / 7분 초과 4(진행 길이 갱신은 2026-08-09 배선 — 세션 Feature 가 면접 시작 시와 백그라운드 마감마다 덮어쓴다). [처음부터 시작] 확정 = `abandonSession(USER_EXIT)`(진행분 리포트 트리거 — 안내줄 «이용권이 하나 차감됩니다.» 의 근거, 409 는 «이미 중단 완료» 취급) → 보관값 clear → 곧장 [시작하기] 와 같은 위저드(사용자 결정). [이어서 진행] = `checkResume` → RESUMABLE 이면 `confirmResume` → 면접 cover(`InterviewFeature.State(sessionId:resume:)` — 2026-08-09 배선: 확정 응답의 `nextQuestion` + held 근사초를 시드로 readiness 를 건너뛴다 → 2026-11-23 개정: 준비 화면부터 열고 시작 탭이 시드로 세션을 연다, [[interview#코디네이터]]). ENDED·레이스는 보관값 clear + 세그먼트 폐기(`discardRecording`) + 홈 재판정. INVALID → SttFailure 는 준비 화면 복귀엔 배선됐고 **홈 탭 경로의 화면 전환만 TODO #69**. **2026-11 개정 — 재개 가능 여부는 서버가 정한다**: 보관값이 있으면 프로세스를 가리지 않고 카드를 그리고 실행·복귀 시점에 `checkResume` 으로 검증한다(앱이 죽었다 살아나도 이어가며, 영상은 이을 수 없어 영상 없이 진행 — [[interview#Client 계약]]). 상세는 [[app]]·[[home]].

**추가 (2026-08-04 배선)** — 확장 자리 진입도 «스크롤» 이다: 기본 자리에선 목록 스크롤을 끄고 목록 판 위 스와이프를 시트 올리기로 쓴다(확장 자리에서만 목록이 스크롤된다 — 같은 축이라 둘을 동시에 살리면 서로 먹는다). 내려오는 길은 헤더 드래그.

**추가 (2026-07-31 배선, 2026-08-01 개정)** — 시안에 위젯① 버튼이 없고 문구(«밑으로 스크롤해서 면접을 시작해 보세요!»)만 있어, 면접 시작 화면 진입을 **리포트 시트 드래그**로 열었다(2026-08-04: 안내 문구 탭 폐기 — 문구는 문구일 뿐). 시트는 세 자리(면접 시작 / 기본 / 목록 확장)를 오가고 면접 시작은 그중 아래 자리다 — 별도 present 가 아니라 시트 뒤에 깔린 겹이라 손을 놓기 전까진 되돌릴 수 있다(임계값 60pt, 미달이면 기본 자리). 모션 시안이 없어 임계값·스프링은 구현자 판단이고 코드에 TODO 로 표시했다 — 시안 수령 시 확정. 게이트(`checkStartEligibility`)는 아직 없어 무조건 열린다.

**추가 (2026-08-07 개정, 이슈 #73)** — 목록 스크롤과 시트 확장을 **한 제스처**로 합쳤다: 목록 판을 UIScrollView 브리지(`HomeSheetScrollView`)로 감싸 확장 높이까지는 스크롤 이동량을 시트로 흘리고, 그 높이에 닿는 순간 같은 손짓이 그대로 목록 스크롤로 이어진다(확장 자리에서 목록 맨 위를 아래로 당기면 반대로 시트가 내려온다). 위 08-04 의 «자리별로 한쪽만 산다» 는 이 브리지로 대체됐다 — 착지 판정(임계 60pt·관성 보정)은 그대로 `HomeSheetDrag` 다.

### 위젯 ② 면접 기록 (마이페이지 PRD 3.3·3.4 이관)

세션당 1행·최신순, MVP 최대 3~4행 전체 노출(페이지네이션 없음). 행 탭 → 펼침(foldable, 재탭 접힘) = 메타데이터 + [레포트 보기].

| 행 상태 | 조건 | 펼침 후 [레포트 보기] |
|---|---|---|
| 1차 레포트 | 지인 피드백 0건 | 상세 리포트(r1) 뷰 |
| 최종 레포트 | 지인 피드백 1건 이상 — **도착 즉시 갱신, 확정 시점 없음** | 최종 레포트 뷰 + «마지막 업데이트» 시각 |
| 레포트 생성 실패 | 생성 영구 실패 (**미차감**) — 종료 상태, 자동 재생성 없음 | 진입 버튼 없음. «레포트 생성에 실패했어요 · 횟수는 차감되지 않았어요» |

**상태별 노출 (2026-08-04 확정)** — PRD 표는 1차/최종/실패 3종뿐이라 API `reportStatus` 4종([[api#Interview]])과 어긋난다. 결정: **GENERATING 은 행을 만들지 않는다**(채점 끝나기 전 세션은 목록에서 뺀다 — 홈은 폴링하지 않으니 다음 진입 재조회 때 나타난다). **INSUFFICIENT_ANALYSIS 는 채점된 카드만이라도 리포트가 있으니 READY 와 같은 행**이다. **FAILED 는 전용 행**(시안 2026-08-05) — 제목 «레포트 생성에 실패했어요» + 회색 보조 문구 «이용권 횟수는 차감되지 않아요», [레포트 보기] 없음.

메타데이터(전부 **세션 스냅샷** 값): 직군·연차(면접 당시 값) / 포트폴리오 파일명(원본 삭제 시 «삭제된 포트폴리오» 배지 + 파일명 유지) / JD(url 문자열 또는 «JD 직접 입력») / 시각 4종(서버 시간 — 면접 진행·레포트 생성·지인 피드백 요청·최종 마지막 업데이트).

[레포트 보기] → `InterviewReportFeature` 는 cross-feature — `delegate` → AppFeature 제시([ai-interview-report](ai-interview-report.md)).

**추가 (2026-07-31 배선)** — 목록·펼침은 `HomeFeature.State` 가 든다: `reports: IdentifiedArrayOf<Report>`(개수는 `reports.count` 파생) · `expandedReportIDs`(집합 — 리듀서 토글). **2026-08-05 개정: 복수 펼침 허용** — 진입 시 최신 1개만 펼치고, 펼친 카드 본문을 탭하면 그 행만 접힌다([>] 버튼 영역은 상세 진입이라 접힘과 겹치지 않는다).

**추가 (2026-08-04 배선) — 목록이 서버에서 온다.** `InterviewClient.reportList`(GET /interview/sessions)를 홈 진입 로드에 붙였고, 행 모델 `Report` 는 `id`(= 세션 id) · `dateText`(«7월 11일 토» — KST·ko_KR 고정 포맷) · `title` · `canOpenReport` 다. 행 노출은 `reportStatus` 로 갈린다(아래 «상태별 노출» 참조). 기록이 있으면 phase 는 **`report(.returning)`** — 인사말을 띄운다(«오랜만/최근» 판정 재료가 없어 `recent` 는 프리뷰 전용). 확장 자리(시트가 내비바 밑까지 올라온 상태)는 시안 [649:6625](https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=649-6625) 대로 그래버 없이 헤더+목록만 남고, 판 위쪽에 내비바 그림자(0 8 6 · #DDDFE5 60%)가 깔린다(2026-08-05). 아직 미구현: 지인 피드백 유무로 갈리는 1차/최종 구분(`feedbackAvailable` 만 받고 안 쓴다) · 메타데이터 4종(포폴 파일명·삭제 배지·JD·시각).

**추가 (2026-08-07) — 행 제목이 «답변 한 줄 요약» 이 됐다.** 목록 응답에 `title` 이 붙어 `Report.title(for:)` 이 그 문장을 쓴다. 비거나 없으면 세션 스냅샷(직군·연차)으로 떨어지는데, 그 갈래는 필드 이전에 만들어진 과거 세션 몫이다. 실패 행은 그대로 «레포트 생성에 실패했어요» 다.

### 잔여 무료 횟수 — 홈 단독 표시

서버 값 표시만(«진실은 서버에만»). 표기 «N회 남음» 뿐 — 진행 중 구분 없음. **마이페이지에는 표시하지 않는다.** 0회 도달 시 위젯① 이 NO_REMAINING 안내로 전환. 시작 버튼 옆이 제자리(판단 재료).

### 위젯 ③ 마이페이지로 이동

단순 진입 버튼 — 프로필(직군·연차)·포트폴리오 관리(Part 5 Feature — 미존재, delegate 자리만). 포폴 없으면 «포트폴리오 등록 필요» 표시 여부는 디자인 결정 — 위젯① PORTFOLIO_NOT_READY 의 예고 장치.

### 빈 상태 (첫 사용자)

잔여 «3회 남음»(계정 생성 시 부여) / 위젯① 탭 → 게이트 PORTFOLIO_NOT_READY → 포폴 등록(S2)부터 — **홈이 온보딩 진입점** / 위젯② 빈 문구(«아직 면접 기록이 없어요…» — 디자인 확정) / 위젯③ «포트폴리오 등록 필요».

## 4. Cross-feature 라우팅 (delegate → AppFeature)

```
Splash 판정(AppFeature 자체) ──게이트 2단──▶ 홈 | Auth(약관·온보딩·로그인) — launch-routing.md
Auth --delegate(.signedIn)-------------------▶ AppFeature → 홈 ✅ (발원지: 두 게이트 통과 즉시 /
                                               약관 통과 + 프로필 등록됨 / 온보딩 등록 완료)
Home --delegate(.startInterviewRequested)----▶ AppFeature — 게이트 결과별: 면접 위저드 fullScreenCover /
                                               S2 강제 / AuthSuspension 제시 / 홈 내부 안내
Home --delegate(.resumeInterviewRequested(sessionId))▶ AppFeature → InterviewFeature(sessionId) fullScreenCover
Home --delegate(.reportRequested(sessionId))-▶ AppFeature → InterviewReportFeature (r1/최종은 리포트 도메인 내부)
Home --delegate(.myPageRequested)------------▶ AppFeature → 마이페이지 (Part 5 — Feature 생기면)
Onboarding --delegate(.finished(sessionId:))-▶ AppFeature → 면접 시작 ✅ (2026-08-03 — [ai-interview] §2)
Interview --delegate(.finished/.closed)------▶ AppFeature → cover 닫고 홈 ✅ (2026-08-03)
```

기존 dev 임시 진입(`showsOnboardingEntry`·`showsDebugLogout`)은 제거됐다(2026-08-03) — 온보딩 진입은 위젯①로 흡수됐고, 남은 dev 버튼은 «데이터 전부 삭제 후 재시작»(`showsDevReset`) 하나이고, 자리는 **인사말 옆**이다(2026-08-05 — 시트 빈 상태에 있어 기록이 생기면 사라졌다). 정식 로그아웃은 마이페이지(Part 5) 몫.

**추가 (2026-08-03) — 면접 cover 는 이미 조립돼 있다.** `AppFeature` 에 `@Presents var interview` + `.ifLet` + `AppView` fullScreenCover 가 들어갔고(dev 게이트 없음 — 전 계에서 동작), 면접 중에는 전역 LoadingModal 을 끈다. `interviewStartRequested` 를 여는 사람은 **게이트 판정 후 `state.interview = InterviewFeature.State(sessionId:)` 한 줄만** 채우면 된다 — cover 제시·종료 라우팅은 재구현 대상이 아니다. `resumeInterviewRequested(sessionId:)` 도 같은 cover 를 재사용한다.

**추가 (2026-07-31 배선) — 위 표의 delegate 4건이 실제 케이스로 들어갔다.** 이름은 구현 기준: `interviewStartRequested`(StartInterview 의 [시작하기]) · `interviewInfoEditRequested`([수정하기]) · `profileRequested`(마이페이지) · `reportDetailRequested(sessionId:)`(리포트 상세 — 인자는 세션 id 다, 2026-08-04 목록 배선으로 교체 완료). `AppFeature` 는 네 케이스를 **명시로 받고 `.none` + TODO** 였다(아래 08-02 추가에서 앞 두 건이 위저드로 배선됐다). `resumeInterviewRequested(sessionId:)` 는 held 세션 로드가 없어 아직 만들지 않았다. 홈 내부에 남는 것: 펼침 토글(`userTappedReportRow`)·면접 시작 화면 present.

**추가 (2026-08-02 배선) — 앞 두 건이 온보딩 위저드로 연결됐다.** 면접에 필요한 정보(직군·연차·JD·포폴)를 모으는 게 온보딩이라, `interviewStartRequested` 는 **첫 면접일 때만**(`startInterview.variant == .first`) 위저드를 `fullScreenCover` 로 연다. `.hasPortfolio` 는 수집을 건너뛰고 면접으로 가야 하는 자리라 TODO 로 남았다(`FeatureInterview` 미통합). `interviewInfoEditRequested` 는 변형과 무관하게 같은 위저드를 처음부터 태운다 — 저장된 draft 가 살아 있으면 위저드가 값을 복원한다(TTL 14일). 위저드가 닫힐 때(`finished`·`dismiss` 둘 다) AppFeature 가 `.home(.view(.onAppear))` 를 보내 홈을 재조회한다 — 중도 이탈이라도 STEP4 업로드는 끝났을 수 있어 «이전 정보 재사용» 카드가 옛 값으로 남으면 안 된다. `profileRequested` 는 여전히 `.none` + TODO.

**추가 (2026-08-05 배선) — 위젯② 가 리포트로 이어졌다.** 기록 리스트를 `InterviewClient.reportList` 로 매 진입 재조회하고(`inner(.reportsLoaded)` — 실패는 nil «모른다» 로 와 직전 목록을 지우지 않는다), 행 id 를 **세션 id** 로 바꿔 `reportDetailRequested(sessionId:)` 가 그대로 `ReportFeature.State(sessionId:)` 를 연다(fullScreenCover). 채점이 안 끝난 세션도 그냥 연다 — 미생성·GENERATING 은 리포트 화면이 폴링해 채우므로 홈이 같은 판정을 또 갖지 않는다. 행 제목은 목록 응답에 `headline` 이 없어 세션 스냅샷(«백엔드 개발자 · 3년차»)으로 세운다 — 시안 문구는 요약문이라 서버 확장 시 교체하고, 생성 실패·삭제된 포폴 태그(§6)는 홈 시안에 자리가 없어 아직 안 그린다.

## 5. Client / Domain 영향

홈 진입 시 로드 — 묶음 API 1회 vs 개별 호출은 서버 협의(미결 #1). **서버 2종(프로필 2026-08-02 · 기록 목록 2026-08-04) + held 로컬 판정(2026-08-08)** 으로 완결 — 포폴 로드는 분기 폐기로 제거(2026-08-08). 프로필은 `inner(.entryLoaded)` 한 케이스로 받아 묶음 API 로 바뀌어도 갈아끼울 자리가 하나고, 기록 목록은 느려도 인사말을 막지 않게 별개 effect(`inner(.reportsLoaded)`), held 는 `HeldSessionStore.load()` 동기 읽기(effect 아님)다.

**갱신 주기 = 매 진입 재조회**(첫 진입만 로드하지 않는다). 포폴은 온보딩 S2·마이페이지가, 잔여는 면접이 바꾸므로 캐시하면 무효화 신호를 Feature 밖으로 돌려야 하는데(Feature→Feature 금지) 1건짜리 GET 세 번보다 비싸다. §6 «지인 피드백 도착 직후 홈 복귀 → 재조회로 실현» 과도 같은 태도다. 부분 실패는 허용하고(한쪽이 죽어도 나머지는 그린다) 값은 덮어쓰기만 한다 — 재진입마다 비우면 깜빡인다. 상세는 [[home#진입 로드]].

| 데이터 | Client (모듈) | 상태 |
|---|---|---|
| 잔여 횟수·이름 | `UserClient.profile` → `remainingTicketCount`·`name` — PRD 표기 `GET /me/entitlement` 와의 대응은 묶음 API 협의와 함께 확정 | ✅ 2026-08-02 배선 |
| 면접 기록 리스트 | `InterviewClient.reportList` → GET /interview/sessions(`[InterviewReportSummary]`) — 세션 스냅샷 + `title`(답변 한 줄 요약) + `reportStatus` + `feedbackAvailable` + 포폴 삭제 여부 | ✅ 2026-08-04 배선, `title` 2026-08-07 — 🟠 잔여: 시각 4종·1차/최종 구분 |
| 진행 중(held) 세션 유무 | `HeldSessionStore` 로컬 보관(서버 목록 API 없음) + 탭 시 `checkResume` 재검증 | ✅ 2026-08-08 배선(§3 «08-08 배선» 문단) |
| 포폴 상태 (위젯③·빈 상태·재사용 카드) | ~~`PortfolioClient.list`~~ 홈 재사용 카드·포폴 로드는 2026-08-08 분기 폐기로 제거. 위젯③ 표시는 Part 5 와 함께 재론 | 폐기 |
| 시작 게이트 | 신규 — `checkStartEligibility`(사전확인·선택)· 사유 코드 `ACCOUNT_SUSPENDED`·`NO_REMAINING`·`PORTFOLIO_NOT_READY`·`CONSENT_VERSION_STALE`·`RATE_LIMITED`. 기존 `createSession` 에러(`NO_REMAINING_TICKET` 등 — [[api#Interview]])와 코드 체계 정리 필요 | 🔴 서버 협의 |
| A1 동의 제출 | `ConsentClient.pending`·`document`·`submit` (3회 부여는 서버가 첫 제출 시) | ✅ 2026-08-01 |
| 자동 로그인 판정 | `AuthClient.isAuthenticated`·`refresh` + `ConsentClient.pending` (게이트 2단) | ✅ 2026-08-01 — [launch-routing](launch-routing.md) |

HomeFeature 는 «외부 IO 없는 Feature 예시»([[home]])에서 벗어났다 — `.domain(interface: .interview)`·`.domain(interface: .portfolio)`·`.domain(interface: .user)` 가 붙었다(2026-08-02·2026-08-04). 화면 상태는 서버 판정의 표시일 뿐(탭 시점 게이트가 진실 — TTL 레이스 미결 #4 도 «탭 시 재검증»으로 흡수 제안):

```swift
// 홈 화면 — GuestFeedback 패턴 (State.phase → 뷰 스위치). §3 «구현 시 수정» 반영 후 2종
public enum Phase: Equatable, Sendable {
    case `default`                       // HomeDefault
    case report(ReportVariant)           // HomeReport — 인사말 표시 여부가 축
    // case startInterview(Start)        // → StartInterviewFeature 로 분리 (cover present)
    // case duringInterview(During)      // → MVP 제외로 삭제 (2026-07-31)
}
public enum ReportVariant: Equatable, Sendable { case returning, recent }
// 면접 시작은 별 Reducer: StartInterviewFeature.Variant { first, inProgress(remainingQuestionCount:), exhausted }
// (삭제) During: Equatable, Sendable { case inProgress, reportGenerating } — MVP 제외
// 위젯② 행별 상태는 phase 와 별개 유지:
enum ReportRow { case first; case final(lastUpdatedAt:); case generationFailed } // + foldable 펼침 상태
```

## 6. 엣지 케이스 (병합 — 클라 판정분)

| 상황 | 처리 |
|---|---|
| 잔여 0 + 기록 3건 | 위젯① 소진 안내, 기록 열람은 그대로 — «다 썼어도 기록은 남는다» |
| 포폴 삭제 + 기록 존재 | 행 펼침에 «삭제된 포트폴리오» 배지, 위젯③ «포트폴리오 등록 필요» |
| 교체 소진 + 포폴 0 | PORTFOLIO_NOT_READY 안내에 «다음 달 1일부터 업로드 가능» 병기 |
| 지인 피드백 도착 직후 홈 복귀 | 해당 행 즉시 «최종» + last updated (홈 재진입 시 재조회로 실현) |
| 진행 중 세션 채로 홈 재진입 | 위젯① = [이어서 진행], 같은 session_id (표시 후 TTL 만료 레이스 → 미결 #4) |
| A1 동의 전 앱 종료 | 계정 미생성 — 재로그인 시 A1 재진입 (서버 판정) |
| 카카오·Apple 각각 가입 | 계정 2개 생김(막을 수 없음) — Part 5 제공자 배지가 완화 장치 |
| 정지 + 동의 구버전 겹침 | 게이트 순서상 정지(게이트 1) 우선 → A4 |
| 탈퇴 직후 같은 소셜 재로그인 | 신규와 동일(A1 부터), 과거 기록 안내 없음 |
| 재동의 [나중에] 후 면접 시작 | 게이트 3 차단 → A3 재진입 (MVP: 자리) |

## 7. 미결 & 블로커

| # | 항목 | 소유 | 클라 영향 |
|---|---|---|---|
| 6-1 | 홈 진입 API 묶음(1회) vs 기존 개별 + 기록 목록에 «답변 한 줄 요약» 문장 필드 | 서버 | 🟡 블로킹 없음 — 프로필·기록은 기존 계약, held 는 로컬 판정(2026-08-08). 요약 문장 필드는 `title` 로 도착·배선 완료(2026-08-07) ✅ — 없는 과거 세션만 직군·연차다 |
| 6-2 | 위젯③ 미리보기·빈 상태 문구 | 디자인 | 🟡 문구 슬롯만 — [이어서 진행] 은 2026-08-07 시안 수령(443:5890·5873)으로 해소 |
| 6-3 | ~~held 세션 resume 경로~~ | 서버→클라 | ✅ 2026-08-08 해소 — resume API 확정 + `HeldSessionStore` 로컬 보관·배선(§3 «08-08 배선»). 2026-08-09 로 녹화 길이 갱신·nextQuestion 재개 진입까지 배선 완료. 잔여: INVALID → SttFailure **홈 탭 경로**만 미도안(TODO #69 — 준비 화면 복귀엔 배선됨) |
| 6-4 | [이어서 진행] 탭 시점 재검증(TTL 만료 → «세션 만료·미차감» 안내?) | 정책 | ✅ 2026-08-08 — 탭 시 `checkResume` 재검증으로 흡수(만료면 보관값 폐기 + 홈 재판정, 별도 안내 없음 — 문구가 생기면 재론) |
| S-1 | 소셜 인증~동의 제출 사이 서버 상태(임시 토큰)·«동의 제출=계정 생성» 계약 | 서버 | 🔴 A1 API 블로커 |
| S-2 | 국외 이전 동의 전문 | 벤더 대기 | 🟡 뼈대 먼저 |
| S-3 | 재동의 변경 요약 | — | 소멸 (2026-07-29 확정 — 첫 개정 시점 이월) |
| S-4 | 카카오 이메일 필수화(비즈앱) 여부 | PM | 🟠 미제공 시 차단/허용 분기 |
| S-5 | CS 이메일 주소 | 운영 | ✅ 확보 — AuthSuspension mailto |
| 신규 | 직군·연차가 가입 플로우로 이동 → 면접 위저드 S0 처리(스킵 vs 프리필) | PM | 🟠 위저드 개편 범위 (제출 시점은 연차 CTA 일괄로 해소 2026-08-02) |

측정(위젯 클릭률·전환율·A1 완료율·재동의/정지 카운트)은 애널리틱스 도입 시 이벤트 설계로 이월([ai-interview](ai-interview.md) §5 와 동일 태도).

## 8. 수용 기준 (병합 — iOS 관련분)

1. 신규: AuthCreateAccount → 소셜 인증 → AuthTerms(5종 체크) → 제출 → 계정 생성·무료 3회·이력 저장 → 가입 온보딩(이름·직군·연차·등록 완료) → 홈 (iOS — A2 없음).
2. AuthTerms 이탈 후 재로그인 → AuthTerms 재진입, 계정·이용권 없음. 필수 5종 중 4개 체크 → 버튼 비활성.
3. 기존 회원 로그인 → 약관·온보딩 없이 홈. (동의 구버전 → A3 는 MVP 자리만.)
4. 첫 사용자 홈: 잔여 «3회 남음», 기록 빈 상태, 위젯① → 포폴 등록(S2) 라우팅.
5. 정상: 위젯① → 게이트 통과 → S0 프로필 직군·연차 프리필.
6. 진행 중 세션: 재진입 시 위젯① = [이어서 진행], 같은 session_id 복귀, 새 예약 생성 없음.
7. 잔여 0: 위젯① 소진 안내, 기록 열람 정상.
8. 기록 행 탭 → 펼침/재탭 접힘. [레포트 보기] → 1차=r1 / 최종=최종 뷰. 피드백 1건 도착 → 즉시 «최종»+last updated.
9. 생성 실패 세션 → «생성 실패·횟수 미차감» 행, [레포트 보기] 없음, 잔여 불변.
10. 포폴 삭제 후 → 행 배지 «삭제된 포트폴리오», 위젯③ «포트폴리오 등록 필요».
11. 잔여 횟수는 홈 단독 표시(마이페이지 미표시).
12. 정지 계정: 로그인·레포트 열람 정상, 면접 시작 시 A4 + CS 메일 버튼 동작.
13. 탈퇴 후 재가입 → A1 부터 신규 흐름, 무료 3회 재부여.

## 9. 빌드 순서 제안

UI 는 전 단계 공통으로 **Figma 시안 수령 후 연결**(figma-screen) — 그 전엔 리듀서·Path·phase 골격과 mock 데이터까지.

1. ~~**AppFeature 루트 게이트 확장**~~ ✅ 2026-08-01 — Splash 세션 복구(refresh + pending) + `State.root` enum + 재시도. [launch-routing](launch-routing.md).
2. **FeatureAuth 가입 플로우** — 골격 ✅ 2026-07-31 (코디네이터 `AuthFeature` + 화면 6종 + Example 완주 데모, STEP1·2 는 복사), 동의 제출·게이트 2단 분기 ✅ 2026-08-01, 프로필 일괄 PATCH ✅ 2026-08-02. 잔여 🔴: 실패 토스트, Figma UI.
3. **FeatureHome 개편** — phase 골격 ✅ 2026-07-31 (`Phase` 4종 + 서브뷰 스텁), 진입 로드(프로필 ✅ 2026-08-02 · 기록 목록 ✅ 2026-08-04 · held 로컬 판정 ✅ 2026-08-08, 포폴 로드는 폐기). 잔여 🔴: 위젯 3종 UI·빈 상태 (게이트 API 전엔 mock).
4. **Domain 신규 계약** — 게이트 (미결 6-1·S-1 서버 협의 후). 기록 리스트는 `InterviewClient.reportList` ✅, held 세션은 resume 3종 + `HeldSessionStore` ✅ 2026-08-08.
5. **라우팅 배선** — 위젯①→면접 위저드/면접(작업 D 합류)·AuthSuspension, 위젯②→리포트 ✅ 2026-08-05, 위젯③→마이페이지(Part 5 대기). dev 임시 버튼 제거 ✅ (데이터 초기화 1개만 유지). 면접 위저드 S0 정리(§7 신규 미결 — 원본 STEP1·2 제거 포함).
