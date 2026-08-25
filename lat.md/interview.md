# Interview 도메인

AI 면접 연습의 중심 도메인. `DomainInterview` 가 D14 면접 세션 API([[api#Interview]])의 모델과 Repository 계약(`InterviewClient`)을 보유하고, Part 2 화면군은 `FeatureInterview` 가 구현한다([[interview#면접 흐름]]). 소비 Feature 는 `.domain(interface: .interview)` 로 연결된다.

## Client 계약
`InterviewClient` 는 Feature 가 Interview 데이터에 접근하는 유일한 통로다 — 세션 생성·준비 폴링·턴 루프(답변 제출)·질문 TTS·재개·중단·레포트 목록을 한 struct 로 노출한다.

멤버는 `createSession`(생성)·`sessionStatus`(준비 폴링)·`submitAnswer`(답변 제출 = 턴 루프의 축)·`questionAudioStream`(질문 TTS 재생 정보)·`checkResume`(재개 가능 조회)·`confirmResume`(재개 확정 — 응답은 `submitAnswer` 와 같은 `AnswerResult`)·`abandonSession`(중단 — `AbandonCause` 는 USER_EXIT/NETWORK_DISCONNECT 만, HOLD_EXPIRED 는 서버 내부 전용이라 타입에서 뺐다)·`reportList`(내 레포트 목록 — 홈 진입 로드가 쓴다, [[home#진입 로드]]).

같은 모듈의 `HeldSessionStore` 는 진행 중(held) 세션의 **로컬 보관** seam(UserDefaults) — 서버에 진행중 세션 목록 API 가 없어 클라가 `sessionId`(+ 녹화 길이 `recordedSeconds` + 프로세스 표식 `processToken`)를 들고 있어야 홈이 «진행 중» 을 판정한다([[home#진입 로드]]). 수명: **온보딩 완주(= 서버에 세션이 생기고 이용권이 잡히는 순간) 에 `hasStarted false`·표식 없음으로 저장**(2026-08-21) → [시작하기] 탭에서 `hasStarted true` → 세션 화면이 녹화를 열 때 표식 스탬프 → 백그라운드 마감마다 누적초·토큰으로 갱신 → 완료·중단·ENDED 판정 시 삭제. 여는 시점이 «세션 생성» 인 건 회수 경로(킬 클린업·복귀 검증·홈 두 갈래)의 입구가 전부 `load()` 라 장부가 비면 회수 기계 전체가 no-op 이기 때문이다 — 2026-08-18~21 사흘간 «시작하기 탭 저장» 이었고(#130) 그동안 준비 화면에서 이탈한 세션이 전부 서버 IN_PROGRESS 고아로 남아 마이페이지 포폴 삭제를 막았다.

**소유 분담**(2026-08-08 배선 완료 — #69 «녹화하며 갱신» 이 해소된 지점이다): 앱 코디네이터([[app#Cross-feature Routing]])가 생성 save(0초·표식 없음)·완주 clear·홈 두 갈래(abandon 성공·재개 ENDED)의 clear·킬 클린업 clear 를 맡고, 면접 쪽은 **시작 시 표식 스탬프**·백그라운드 마감의 누적초 **갱신**·오버레이 중단(`NETWORK_DISCONNECT`) 뒤 clear([[interview#세션]])·복귀 ENDED 판정의 clear([[interview#코디네이터]])를 맡는다. `processToken` 은 «**이 프로세스에서 면접이 시작됐다**» 는 표식(프로세스당 상수 `currentProcessToken`)으로 세션 화면이 녹화를 열 때(`recordingStarted`) 찍히고, 재개 제안 판정 `isResumableInCurrentProcess`(표식 없음 ‖ 현재 프로세스)가 죽은 프로세스의 세션을 걸러 앞부분 없는 영상 재개를 막는다 — 세그먼트가 tmp·프로세스 수명이라서다([[interview#프리뷰]]).

⚠️ 판정 기준이 «0초 여부» 가 아니라 표식인 건 2026-08-09 결함 수정이다 — `recordedSeconds` 는 백그라운드 마감에서만 갱신돼, **백그라운드를 거치지 않고 죽은 면접**(크래시·메모리 압박·동결 완주 전 강제 종료)이 0초로 남는다. 옛 규칙(0초 = 무조건 재개 가능)은 그걸 갓 시작한 보관분(표식 없음)과 구분하지 못해 킬 클린업이 대상으로 잡지 못했고, 서버 세션이 영영 살아남았다. 표식 없는 구버전 저장값만 옛 규칙(0초 여부)으로 접는다. 킬 클린업의 판정은 Interface 순수 함수 `HeldSessionCleanup` 이 맡는다(효과는 AppFeature 가 싣는다): `target` 은 홈 카드 술어 `isResumableInCurrentProcess` 의 **부정**을 그대로 쓴다 — 다른 프로세스에서 시작된 세션만 대상이고, 표식 없는 값(시작 직후·**시작 전 장부**)과 현재 프로세스 값은 불가침이다. 시작 전 장부를 여기서 닫으면 앱을 껐다 켠 사용자가 잡힌 이용권을 회수 동선 없이 잃는다(2026-08-21). 홈과 술어를 공유해야 «카드는 숨는데 클린업이 줍지도 않는» 틈이 구조적으로 불가능해진다, `followup` 은 RESUMABLE → `abandon(USER_EXIT)` · ENDED → 로컬 정리로 가른다. App 테스트 타깃이 없어 결정표는 `HeldSessionCleanupTests`·`HeldSessionTests` 가 유닛으로 고정한다.

Interface 에 계약 + `testValue`(unimplemented) + `previewValue`(샘플), Implementation 에 `liveValue` — 구현은 App/Example 만 link 한다(D4).

- 입력 모델 `InterviewConfig` 는 Setup 위저드 산출물 — jdUrl/jdText 상호 배타는 `JobDescriptionInput` enum 으로 타입에 새겼다.
- `questionAudioStream` 은 Data 가 아니라 `InterviewAudioStream(url·headers)` 를 준다 — chunked TTS 를 AVPlayer 로 점진 재생해야 해서다([[api#Interview]] 스트리밍 규약). 이 구조상 서버(Tomcat)엔 매 턴 `Broken pipe`(disconnected client)가 남을 수 있고 **정상이다**(2026-08-07 백엔드 합동 확인) — AVPlayer 의 프로브 연결 정리, 다음 재생의 선행 `stop()`, 이탈 전환의 `stopPlayback` 이 전부 mid-stream TCP 종료라서다. 클라 결함 신호가 아니며 대응은 서버 로그 레벨 조정 몫.
- 영상 업로드 3단(발급 → S3 presigned PUT → 완료 확정)은 응집형 `uploadInterviewVideo(sessionId·fileURL·wrapUp)` 와 단계 seam(`videoUploadURL`·`completeVideoUpload`) 두 벌로 노출된다([[api#Interview]]). 응집형은 순서·PUT 실패 시 complete 생략을 도메인이 보장하는 **1시도 계약**(PUT 은 [[domain.map#네트워킹 인프라]] `FileTransferClient` 로 스트리밍, 발급 응답 `contentType` 원문 전달)이고, 재시도(발급부터 재시작) 정책은 호출처 몫이다.
- **실 면접 경로는 그 응집형을 쓰지 않는다**(2026-08-06) — [[interview#업로드 큐]] 가 단계 seam 을 직접 조립한다. background 전송은 등록(발급→PUT 등록)과 완료(complete)가 **프로세스 경계를 넘어 갈라지므로**(앱이 죽어도 PUT 은 이어지고 완료 이벤트는 다음 실행에 온다) 한 함수의 await 안에 응집할 수 없다. 응집형은 계약·단독 검증·수동 조작용으로 존치한다 — 현재 프로덕션 호출처 0, 호출은 `InterviewClientLiveTests` 뿐이다.
- 에러는 `InterviewError`(도메인) 로 노출한다 — liveValue 가 Core `ServerError` 코드를 전용 케이스(`.freeTextNotRelevant`·`.noRemainingTicket`·`.answerAlreadySubmitted` 등, 전체 표는 [[api#Interview]])로 매핑하고, 입력 검증군은 `.invalid(message)`, 미승격 코드는 `.server(code,message)` 로 동봉해 Feature 가 Core 를 모르고도(레이어) 코드별 분기한다. 온보딩 프리로드가 `.freeTextNotRelevant` 를 잡아 대표 프로젝트로 되돌린다 → [[onboarding#프리로드]].

## API
서버 계약이 바뀌면 이 섹션·[[api#Interview]]·`liveValue` 를 함께 갱신한다. 인프라는 [[domain.map#네트워킹 인프라]] 의 `AuthorizedNetworkClient` 계약만 사용 — Bearer 첨부·토큰 재발급은 인프라 몫이고 liveValue 는 경로 조립·인코딩·디코딩만 한다.

- 세션 생성은 회원 프로필 스냅샷(직군·연차 미전송 — 미등록이면 `USER_PROFILE_NOT_REGISTERED`). 준비는 서버 비동기: POST(202) → 3~5초 status 폴링 → READY 에 `startedAt` + 요약 질문(base64 TTS). FAILED 는 이용권 자동 환불.
- `submitAnswer` 응답이 턴을 결정한다 — `nextQuestion`(계속) 또는 `sessionEnded` + `SessionEndType` 5종(NORMAL/MANUAL/HARD_CAP/BACK_EXIT(구 EARLY_EXIT)/**STT_RESET** — STT 30% 판정은 서버) + 마무리 멘트(`wrapUpMessage.ttsAudio`). 메타데이터는 query(`isWrapUp` required), 오디오만 multipart. 503(`AI_TEMPORARILY_UNAVAILABLE`)은 서버에 아무것도 저장되지 않아 같은 요청 재시도 계약.
- 재개는 2단 — `checkResume`(GET, 순수 조회)가 RESUMABLE(IN_PROGRESS + hold 20분 이내)/ENDED 를 가르고, RESUMABLE 일 때만 `confirmResume`(POST — 최신 턴 질문 반환, 레이스면 409 아닌 200+`sessionEnded`)을 부른다. ENDED 의 hold 만료 처리(ABANDONED 전환·환불)는 그 GET 안에서 서버가 끝낸다. `abandonSession` 의 USER_EXIT 는 진행분 리포트 생성 트리거(차감은 리포트 성공 시 확정)고, 중복 호출 409 `sessionAlreadyEnded` 는 «이미 중단 완료» 로 성공 취급한다.
- 그 2단과 중단은 **배선 완료**(2026-08-08) — 호출처가 넷이다: 홈 [이어서 진행](`checkResume`→`confirmResume`→시드 cover, [[app#Cross-feature Routing]]) · 준비 화면 복귀(`checkResume` 만 — [[interview#코디네이터]]) · 포그라운드 복귀의 보관값 검증(`checkResume` 만 — [[app#Cross-feature Routing]]) · 킬 클린업(`checkResume`→`abandon(USER_EXIT)`, [[app#Cross-feature Routing]]). `NETWORK_DISCONNECT` 는 세션 네트워크 오버레이의 «중단하기» 전용이고, 오프라인일 공산이 커 **3초 레이스** 뒤 결과와 무관하게 이탈한다 — 남는 서버 세션은 hold 만료 몫으로 위임한다([[interview#세션]]).
- liveValue 는 URLSession·토큰을 모르므로 테스트도 Core 구현 없이 AuthorizedNetworkClient 스텁으로 검증한다 (`InterviewClientLiveTests`).

## 면접 흐름

Part 2 «10분 음성 면접» 화면군 (`FeatureInterview`, Figma «[2] Interview_*» 프레임). 준비 → 세션(네트워크 실패는 세션 위 오버레이) → 정상 종료는 홈 직행·그 외는 실패 화면인 단일 흐름이고, 화면 전환은 전부 [[interview#코디네이터]] 담당. 설계 근거·남은 배선(STT)은 [ai-interview](../docs/work/ai-interview.md) §6.

화면·타이밍·문구는 Part 2 PRD v3 에 정합된 상태(2026-07-27) — 카메라 프리뷰·녹화는 실동작(DomainRecording, [[interview#프리뷰]]), 서버 턴 루프는 실 API(`submitAnswer` — [[interview#세션]], 2026-08-02 작업 C), 질문 TTS·마무리 멘트·세션/답변 실녹음은 [[interview#음성 캡처]] 계약(작업B 슬라이스1). 발화 감지·침묵 판정(슬라이스a)만 남았다.

종료 뒤 영상 업로드는 흐름을 떠나 [[interview#업로드 큐]] 가 이어받는다(2026-08-06 개편) — 화면이 사라져도, 앱이 죽어도 완주시키기 위해서다.

## 코디네이터

`InterviewFeature` 가 흐름 루트 — screen enum destination(준비/세션/실패)을 전면 교체한다. push 스택이 없어 StackState 대신 `@Reducer enum`. 하위 화면의 delegate 만 매칭하고, 흐름 밖(보고서 진입·닫기)은 delegate(.finished/.closed)로 AppFeature 에 올린다. **정상 종료엔 화면이 없다** — 바로 홈이다.

- `State(sessionId:)` 로 온보딩 분석이 만든 세션 id 를 들고 있다 — 준비 화면의 질문 준비 폴링과 세션 시드가 같은 세션을 쓴다. **재개 진입은 `State(sessionId:resume:)` 로 readiness 를 생략하고 세션으로 직행**한다(2026-08-08) — 질문 준비 폴링이 필요 없고(`confirmResume` 이 이미 최신 질문을 줬다) 카메라는 세션 onAppear 의 `startPreview` 가 연다 → [[interview#세션]].
- 시작 전환(startRequested)은 준비 화면의 READY 페이로드(요약 질문)와 프리뷰 핸들을 `InterviewSessionFeature.State(sessionId:summaryQuestion:previewHandle:)` 로 시드한다 — 세션이 첫 턴을 바로 재생한다. **여기서 하는 일은 장부를 «시작됨» 으로 올리는 것뿐이다**(`hasStarted = true` — 2026-08-21): 장부 자체는 온보딩 완주가 이미 열었고([[app#Cross-feature Routing]]), 이 플래그가 서야 비로소 홈이 «진행 중» 카드를 그린다. 읽어서 플래그만 올리고 다시 쓴다 — 통째로 덮으면 표식·누적초가 씻겨 회수 판정이 흔들린다. 장부가 비어 있으면(비정상 — 재개 진입은 준비 화면을 건너뛴다) 새로 연다. 2026-08-18~21 엔 여기가 저장 시점 자체였는데, 그 사이 준비 화면에서 이탈한 세션이 장부 밖에 남아 회수 불가 고아가 됐다(#130).
- 세션 `finished(ref, wrapUp)` 는 산출물을 [[interview#업로드 큐]] 에 접수(`enqueue`)하고 장치를 정지한 뒤 `delegate(.finished)` 를 올린다. enqueue 는 파일 이동+저널까지라 밀리초고, 전송은 큐가 뒤에서 잇는다. 세션 `aborted`·실패 화면 `closeRequested` 는 `delegate(.closed)`.
- **리포트 채점을 기다렸다 홈으로 보낸다**(2026-08-14): 장치 정지 뒤 `interviewReportClient.report` 를 3초 간격으로 폴링해 `status != GENERATING` 이 되면 통보한다. 조회 실패(미생성 404 포함)는 «아직» 으로 보고 다시 묻되, 상한 20회(≈1분)를 넘으면 그대로 통보한다 — 채점 SLA 가 더 길 수 있어 무한정 붙잡지 않고, 홈 목록의 «생성 중» 카드와 리포트 화면 폴링이 이어받는다([[report#1차 리포트]]). 대기 **화면**은 여전히 없다(2026-08-06 개편 유지) — 세션이 이미 세워 둔 `LoadingModal`(`isFinishing`, [[interview#세션]])이 그대로 덮고 있어 인디케이터 한 벌이 종료부터 홈 진입까지 이어진다.
- 종료 신호는 **first-wins**(`isClosing`)다 — 종료 후에도 화면이 `.session` 에 머물러(갈아탈 화면이 없다) `guard case .session` 만으론 늦은 두 번째 세션 delegate 를 못 거른다.
- 화면을 치우는 건 **부모**다 — 코디네이터는 `delegate(.finished/.closed)` 를 올릴 뿐이고, `AppFeature` 가 `state.interview = nil` 로 cover 를 닫는다. 그래서 `InterviewFeature` 를 맨몸 스토어로 띄우면 종료 신호가 정상적으로 올라가는데도 세션 화면에 영영 머문다 — Example 하네스가 그랬고 이걸 제품 버그로 오진했다(2026-08-07). 하네스에도 최소 부모(`ExampleInterviewCoordinator`)를 둬 실앱과 같은 모양으로 맞췄다. 뚫리면 이중 통보이거나, 실패·이탈 경로의 폐기가 **큐에 넘긴 파일**을 지운다 → [[interview#프리뷰]].
- **폐기 책임**은 코디네이터에 있다: 이탈·실패 전환이 `discardRecording()` 을 부르고(멱등), 정상 종료 전환만 부르지 않는다 — 그 파일은 이미 큐 소유라 지우면 안 된다 → [[interview#프리뷰]].
- 준비 `prepFailed` → 실패 화면(kind: questionPrep). 코디네이터가 받는 실패 화면 신호는 `closeRequested` 하나뿐 — 재진입 배선은 없다(`resumeRequested` 는 세션 오버레이 몫, [[interview#실패]]).
- AppFeature 배선 완료(2026-08-03) — 온보딩 `finished(sessionId)` 가 `@Presents var interview` 를 세워 `fullScreenCover` 로 열고, 종료 두 신호(`finished`·`closed`)는 cover 를 닫고 홈을 재조회시킨다(BACK_EXIT 이탈도 리포트 생성 트리거). 케이스를 합치지 않는 건 정상 종료 → 리포트 상세(r1) 연결이 붙을 자리라서다(아직 TODO) → [[app#Cross-feature Routing]].
- **동결 세션의 즉시 이탈**(2026-08-09 개정): 세션이 동결을 마치고 올린 `delegate(.interrupted)`([[interview#세션]])를 받으면 코디네이터는 **판정 없이 곧바로** 나간다 — `suspendRecording(nil)` → `stopPreview` → `stopCapture` 후 자신의 `delegate(.interrupted)` 를 올려 cover 를 닫게 한다([[app#Cross-feature Routing]]). 복귀를 기다렸다 닫던 옛 순서는 그 GET 왕복 동안 동결된 면접 화면을 보여 줬다(«복귀했더니 면접 화면이 깜빡» — 사용자 보고). 백그라운드에서 닫으면 전환 자체가 보이지 않는다. 이 case 는 catch-all(`case .screen, .delegate`)보다 **반드시 앞**에 둔다: 빠뜨려도 컴파일러가 조용히 흡수해 백그라운드를 다녀와도 면접 화면이 남는다(경고 없음).
- `interrupted` 는 **`discardRecording()` 을 부르지 않는 유일한 이탈 경로**다 — 세그먼트가 재개 재료라서. 대신 장치는 놓는다(안 놓으면 홈에서도 카메라가 살아 «계속 보고 있다» 가 된다). 선행 `suspendRecording(nil)` 은 평시엔 no-op(동결이 이미 마감했다)이고, 시작 ~1초 내 백그라운드로 액터에 남은 고아 녹화만 여기서 마감된다 — `stopPreview` 보다 앞인 건 mp4 의 moov 가 캡처세션이 도는 동안 써지기 때문이다([[interview#프리뷰]]).
- **복귀 체크는 준비 화면 전용**으로 남는다: `InterviewView` 가 `scenePhase == .active` 를 `view(.sceneBecameActive)` 로 올리면 코디네이터가 **화면=준비 ∧ `!isClosing`** 일 때만 `checkResume` 을 부른다(백그라운드 관측은 세션 View 몫 — 마감이 세션 소유라서). 세션 화면은 게이트에 걸리지 않는다 — 동결됐으면 이미 나갔고, 살아 있으면(제어센터·알림센터 스침 같은 inactive 바운스, 랩업·합성) 그 운명은 세션 자신이 정한다. ENDED 판정을 들이대면 랩업→enqueue 중이던 영상을 찢는다.

| 준비 화면 복귀의 checkResume 결과 | 처리 |
|---|---|
| RESUMABLE | 무시 — 잃을 게 없어 그 자리를 지킨다 |
| ENDED · INVALID | held clear + 실패 화면(speechRecognition) 교체 — 기존 터미널 재사용 |
| ENDED · 기타(COMPLETED·ABANDONED·PRELOAD_FAILED) | held clear + `delegate(.closed)` — 환불은 서버가 그 GET 안에서 끝냈다 |
| 호출 실패(오프라인 복귀) | 삼킨다 — 그 자리를 지키고 다음 복귀가 다시 묻는다 |

- 홈으로 나온 **뒤**의 «그새 끝난 세션인가» 판정은 루트가 맡는다 — 띄울 면접 흐름이 없으니 자리가 거기뿐이다([[app#Cross-feature Routing]] 복귀 시점 보관값 검증). 그래서 세션 오버레이의 `resumeCheck` 재시도 단계도 함께 사라졌다.
- 즉시 이탈·게이트·준비 화면 4분기는 `InterviewFeatureResumeRoutingTests` 가 고정한다.

## 권한

`DomainPermission` — 카메라·마이크 권한의 유일한 통로 `PermissionClient`(`status(MediaPermission)`·`request`·`openSettings`). iOS 는 사용 시점 요청(PRD §8) 원칙이라 소비처는 면접 준비 화면([[interview#준비]])뿐.

서버 API 가 아닌 디바이스 IO. Interface 에 계약+testValue(unimplemented)+previewValue(전부 granted), Implementation 에 AVFoundation liveValue — App/Example 만 link (D4).

- restricted 는 denied 로 접는다 — 사용자가 못 푸는 상태여도 앱 대응은 "설정 안내"로 동일.
- 마이크도 `AVCaptureDevice(.audio)` 축 — 영상+음성 캡처 세션 기준.
- `openSettings` 를 Client 에 둔 이유: View 의 `openURL` 로 하면 리듀서 테스트로 검증 불가.

## 준비

`InterviewReadinessFeature` — 카메라 확인+안내를 한 화면 4단계 phase(aligning → ready → guide1 → guide2)로 전환. 시작 게이트는 «guide2 + 카메라·마이크 권한 + 질문 준비 READY» 삼중이고, 셋을 다 통과해야 delegate(.startRequested) 를 올린다.

Figma 2479:7569 · 2514:12754 · 2514:12799 · 2529:458.

- 진입 시 카메라·마이크 권한을 요청하고([[interview#권한]]) 하나라도 미허용이면 **그 자리에서** 설정 유도 alert 를 띄운다 — 가이드 phase 는 그대로 흐르되 시작 버튼만 계속 잠긴다. 판정 결과는 `isMediaPermissionGranted` 로 상태에 남겨 뷰의 비활성 조건이 된다(해소 전 기본값 false).
- 좌상단 뒤로가기(2026-08-03 시안, 세션 화면과 같은 DS 네비바)는 **되묻는 모달 없이 즉시** `delegate(.backRequested)` → 코디네이터가 장치 정지 후 `closed`. 아직 질문 재생 전·답변 0개라 확인할 손실이 없다 — 8:00 전 이탈 경고는 «면접 진행 중» 전용이다. 서버 세션은 남지만 재진입 동선은 홈의 «이어서 진행» 몫([home-account](../docs/work/home-account.md) §4).
- 질문 준비(preload, PRD §3.2)는 `InterviewClient.sessionStatus` 3초 폴링(온보딩 분석 스텝과 같은 주기). READY/FAILED 에서 스스로 멈추고, 그 사이 네트워크 에러는 `try?` 로 삼켜 다음 틱 재시도 — «시스템이 알아서 다시 시도» 가 폴링 지속이라 클라 타임아웃도 재시도 버튼도 없다. 최종 실패는 서버 FAILED 만 신뢰한다. READY 는 요약 질문 동봉 시에만 해소(`.ready(SummaryQuestion)` — 세션 시드용) — 페이로드 없는 READY 는 계약 위반으로 보고 폴링을 계속한다.
- 준비 중(preparing)엔 시작 버튼 비활성 — 리듀서도 `questionPrep == .ready` 를 재확인해 레이스를 무시한다. FAILED → delegate(.prepFailed) → 실패 화면(questionPrep).
- 진입 alert 는 [설정으로 이동]=`openSettings` / [닫기]=alert 만 닫고 화면 유지. 닫아도 시작 버튼은 잠긴 채라 남는 길은 «설정으로 이동» 또는 뒤로가기다. **설정에서 허용하고 돌아오면 포그라운드 복귀(`view(.sceneBecameActive)`)가 status 를 다시 읽어** 게이트를 열고 alert 를 닫는다 — 앱 종료·화면 재생성에 기대지 않는다(권한 변경이 항상 프로세스를 죽이지는 않는다, 2026-08-18 리뷰 지적). 카메라가 그때 풀리면 `startPreview`(멱등)로 placeholder 를 실카메라로 바꾼다. 여전히 미허용이면 아무것도 하지 않는다 — 복귀할 때마다 alert 를 다시 띄우지는 않는다. 거부는 앱이 다시 물을 수 없어 재조회는 요청이 아니라 동기 status 읽기고, 리듀서의 시작 탭 가드는 버튼 비활성과 겹치는 레이스 방어일 뿐이다. ⚠️ 이 화면은 `.active` 를 **두 곳**에서 받는다 — 코디네이터 뷰(재개 판정 `checkResume`)와 이 화면 뷰(권한 재조회)로, 목적이 달라 합치지 않았다.
- aligning→ready 는 «최소 유지 시간(3초) + 프리뷰 해소» 이중 게이트 — 실패(권한 거부·시뮬레이터)도 해소로 치고 placeholder 로 진행한다(화면을 막지 않음, 막는 건 시작 버튼). ready 이후는 시간 연출.
- 브래킷 프레임은 DS 로 승격됐다 — `SharedDesignSystem` 의 `CameraGuideFrame`(`Interface/Component/CameraGuideFrame.swift`), 화면은 문구만 넘긴다. 이것과 하단 티커는 에셋 없이 코드 드로잉이고, 블렌드 스위치는 [[interview#프리뷰]].
- 하단 티커(문구 3연속)는 화면보다 넓어 **`overlay` 로 얹는다** — `.fixedSize().frame(maxWidth: .infinity)` 로 두면 넘친 이상적 폭이 부모로 새어 화면 좌표계가 넓어지고, 그 위 네비바가 왼쪽으로 밀려 뒤로가기가 가장자리에 붙는다(`.clipped()` 는 그림만 자를 뿐 레이아웃은 못 되돌린다). 높이·배경은 문구 «한 벌»이 잡는다. 2026-08-03 실기 확인 후 수정.

## 프리뷰

`DomainRecording`(RecordingClient) 이 단일 AVCaptureSession 을 actor 로 소유한다. startPreview 는 멱등 — 준비 화면이 켜고, 핸들 해제(`stopPreview`)는 코디네이터 몫이다. 프리뷰 뷰(backdrop)는 화면이 아닌 `InterviewView` 에 상주해 화면 교체에도 레이어가 유지된다.

- 핸들(`CameraPreviewHandle`)은 identity-Equatable 래퍼 — TCA State 에 저장, 뷰(`InterviewCameraBackdrop`)는 핸들 유무로 실카메라/placeholder 분기.
- backdrop 을 각 화면에 두고 State 시드로 핸들만 이어줘도 전환 시 카메라가 끊겨 보인다(실기기 확인) — `AVCaptureVideoPreviewLayer` 가 화면 교체와 함께 파괴·재생성되기 때문. 그래서 backdrop 은 코디네이터 뷰 상주, 핸들·스크림·모달 배경 블러는 화면 State 에서 파생만 한다(시작 전환 핸들 시드·onAppear 재요청은 백스톱으로 유지).
- 녹화 API 5종은 세션 화면(`startRecording`/`suspendRecording`/`stopRecording` — [[interview#세션]])·코디네이터(`discardRecording`, 복귀 이탈의 `suspendRecording(nil)` — [[interview#코디네이터]])·AppFeature(`purgeRecordings` — 킬 클린업 / `discardRecording` — 홈 두 갈래가 끝낸 세션, [[app#Cross-feature Routing]])가 나눠 부른다. 폐기는 멱등·비던짐이라 «녹화가 있었는지» 분기 없이 이탈·실패 경로에서 무조건 부른다.
- 정지 지점: 준비→실패, 세션→홈(정상 종료), 세션→실패, 세션 이탈 2종(동결·오버레이 중단). 실패·오버레이 중단 전환은 재생(stopPlayback)과 **녹화 폐기**(`discardRecording`)도 함께 하고, 정상 종료 전환만 재생을 살리고(마무리 멘트) 폐기도 부르지 않는다 — 파일 소유권이 [[interview#업로드 큐]] 로 넘어가서다. 동결의 `interrupted` 이탈도 폐기하지 않는다 — 세그먼트가 재개 재료다([[interview#코디네이터]]). 재진입은 Readiness onAppear 가 다시 켠다.
- **세그먼트 원장**(2026-08-08): 한 세션 = 세그먼트 N개다. 백그라운드 경계마다 `suspendRecording(audio:)` 가 현 mp4 를 닫아 (비디오, 세션오디오) 쌍으로 `SegmentLedger` 에 올리고 누적초를 돌려주며(held 갱신 재료 — 미녹화 중이면 nil), `startRecording(sessionId) → Double` 이 새 세그먼트를 열고 그때까지의 누적초를 돌려준다(세션 시계 시드 — 캡처세션이 백그라운드를 다녀와 멎어 있으면 함께 재가동한다). 파일은 tmp `interview-video-<sid>-<n>.mp4`, 합성본은 `interview-recording-<sid>.mp4`(업로드 큐 이관 규칙이 아는 이름이라 유지). 원장은 **Live actor 소유**라 세션 화면이 dismiss 돼도(홈 경유 재개) 프로세스가 사는 한 남고, Feature State 엔 세그먼트 목록이 없다. 반대로 앱이 죽으면 tmp 와 함께 사라져 진행분 재개가 불가능해진다 → [[interview#Client 계약]] 토큰 필터.
- 합성은 **종료 시 1회**다 — `stopRecording(finalAudio:)` 가 마지막 세그먼트를 마감하고 원장 전체를 커서로 이어 붙여 passthrough export 한다. 립싱크 오프셋은 세그먼트 **안**의 (오디오 시작 − 비디오 시작) 호스트시각 차고, 세그먼트끼리는 커서가 정렬을 만든다 — 병합본에 백그라운드 공백이 **없다**는 뜻이라 세션 시계의 raw 축도 동결 중 함께 멈춘다([[interview#세션]]). 세그먼트 0개·**전** 세그먼트 무음은 throw(무음 영상 금지, 일부 세그먼트 무음은 허용) → ref nil = 영상 없는 리포트. 대안 둘은 기각했다 — 재개마다 합성은 사용자 대기(8~10초)를 반복시키고, 세그먼트별 업로드는 서버 저장 위치가 세션당 하나라(병합 API 없음) 불가능하다.
- 마감·시작·정지는 «구간» 플래그(`isSuspending`·`isStarting`·`isStopping`)로 잠근다 — background→foreground 왕복이 정상 흐름이라 마감 중 `startRecording` 이 실제로 겹치고, 안 막으면 아직 원장에 오르지 않은 세그먼트와 **같은 인덱스** 경로를 내줘 마감 중인 파일을 지운다(세그먼트 통째 유실). 마감 구간은 OS 유예(~5초) 안에 닫으려 `beginBackgroundTask` 로 감싼다(정지+합성 구간도 같다 — 랩업은 백그라운드로 밀려도 완주시킨다). 진행 중 들어온 폐기 요청은 각 구간의 defer 가 받아 처리한다.
- `purgeRecordings(sessionId:)` 는 킬 클린업 전용(AppFeature onAppear — [[app#Cross-feature Routing]])으로 **그 세션의** 잔존 파일만 걷는다. 현재 원장 세션이면 무시한다 — 전체 삭제로 두면 클린업과 사용자가 곧장 시작한 새 세션의 세그먼트 0 이 레이스로 함께 지워진다(다른 죽은 잔존물은 tmp 라 OS 몫).
- 원장 계산(누적초·인덱스 경로·세션 전환 리셋·네이밍)은 `SegmentLedgerTests` 가 고정한다 — 실 합성·립싱크는 실기기 E2E 몫이다.
- **정상 종료의 캡처세션 정지는 `stopRecording` 안**이다(2026-08-07) — 코디네이터의 `stopPreview()` 는 합성(8~10초)이 끝나야 도는데, 그때까지 카메라가 켜져 있으면 «종료했는데 카메라가 계속 켜져 있다» 가 된다. 자리가 «파일 마감 뒤·합성 앞» 인 건 mp4 의 moov 가 캡처세션이 도는 동안 써지기 때문 — `waitUntilFinished` 전에 끄면 영상이 깨진다(스파이크도 didFinishRecording 뒤에 stopRunning 하고 merge). 핸들은 남겨 `stopPreview()` 가 해제하게 둔다 — 그래야 다음 세션이 새 AVCaptureSession 을 연다.
- Scope-on-enum 코디네이터는 화면 교체 시 자식 effect 를 취소하지 않는다(`Screen.body` 의 `ifCaseLet` 은 **자기 안에서** 일어난 case 변경만 취소 신호로 본다 — 코디네이터 `Reduce` 의 교체는 그 밖이다). readiness 의 프리뷰 시작 effect 가 화면 교체를 넘겨 살아남을 수 있어, 흐름 이탈(aborted·closeRequested)은 정지 완료 후 상위 통보로 순서를 보장한다(`stopCaptureDevicesThenNotifyClosed` — 마이크 캡처도 함께 정지, [[interview#음성 캡처]]). 같은 이유로 뒤늦은 세션 delegate 가 도달할 수 있어 **세션발 3종(`finished`·`aborted`·`failed`) 전부**에 `guard case .session` + `isClosing` 이중 가드를 둔다 — 늦은 aborted·failed 는 헬퍼의 `discardRecording()` 이 **큐에 넘긴 파일**을 지우고, 늦은 finished 는 이중 통보다(재접수 자체는 큐 dedup 이 한 겹 더 막는다 — [[interview#업로드 큐]]).
- 세션 화면의 백그라운드 전환은 자동 복구에 맡기지 않는다(2026-08-08 개정) — 캡처가 진입 즉시 끊겨 «유예» 자체가 없으므로 세션이 세그먼트를 마감하고([[interview#세션]] 동결), 복귀 후 `startRecording` 이 캡처세션 재가동 + 새 세그먼트로 잇는다. 세션 화면이 아닌 준비·실패 화면의 백그라운드만 여전히 iOS 인터럽션 자동 복구(비디오 전용 세션) 몫이다.
- 브래킷 프레임 Figma color-burn 블렌드는 `CameraGuideFrame(blendsColorBurn:)` 로 구현돼 있고 **기본 꺼짐** — 프리뷰가 UIKit 호스팅 레이어(`AVCaptureVideoPreviewLayer`)라 SwiftUI 블렌드가 그걸 backdrop 으로 합성하지 못한다(투명 배경에 걸려 새까매질 수 있다). 실기기 육안 확인이 끝나면 켠다.

## 음성 캡처

`DomainSpeech`(SpeechClient) 가 AVAudioEngine 마이크 캡처를 actor 로 소유한다(설계: docs/superpowers/specs/2026-07-29-mic-capture-design.md). 세션 화면이 전구간 이벤트 스트림을 구독하고, 같은 tap 이 세션·답변 m4a 2계열도 기록한다(작업B 슬라이스1). 정지는 세션 effect 취소 + 코디네이터 `stopCaptureDevices` 이중.

- 이벤트: `level`(1초 윈도 피크 dBFS) · `speechStarted`(−35 dBFS 상향 돌파) · `speechEnded`(−45 미만 1초 지속 — 히스테리시스) · `captureFailed`. 임계 상수는 실기기 튜닝 여지.
- STT 교체 seam: Interface 에 transcription 엔드포인트를 추가하고 Implementation 이 같은 tap 버퍼를 STT 엔진에 공급 — 소비처(세션 Reducer)는 이벤트 매칭만 확장.
- 소비처는 로그만(State 무변화, `os.Logger` category `MicCapture`) — STT 도입 시 inner 액션으로 승격.
- AVAudioSession 은 `.playAndRecord`(mode `.default`) — 질문 TTS 재생과 마이크 캡처를 한 세션에서 쓴다. 카메라 AVCaptureSession(비디오 전용)과 무충돌.
- 라우팅 옵션은 `[.defaultToSpeaker, .allowBluetoothA2DP]`(2026-08-06) — 이어폰이 있으면 그쪽으로 출력하고, 없으면 리시버 대신 하단 스피커로 떨어뜨린다(거치 상태에서 리시버는 거의 안 들린다). A2DP 는 `playAndRecord` 에선 명시해야 켜진다. **HFP 는 켜지 않는다** — AirPods 처럼 양쪽을 지원하는 기기에서 CoreAudio 가 HFP 를 우선해 면접관 음성이 통화 음질로 떨어지고 답변 녹음까지 8/16kHz 모노가 되어 서버 STT 정확도·최종 영상 음질이 함께 내려간다. 그래서 **마이크는 항상 내장**이다(A2DP 는 출력 전용). 같은 이유로 mode 는 `.voiceChat` 이 아니라 `.default` — `.voiceChat` 은 HFP 를 암묵적으로 켠다.
- 이 설정은 캡처(`SpeechClientLive.startCapture`)와 재생(`AudioPlaybackManager.activatePlaybackSession`) **두 곳이 같은 값**을 들어야 한다 — 갈리면 어느 쪽이 나중에 활성화되느냐로 라우팅이 흔들린다. 세션 **도중** 착탈은 미대응(별도 이슈) — 라우트가 바뀌면 tap 포맷이 갈라져 기록이 조용히 멈춘다. `.defaultToSpeaker` + A2DP 조합이 일부 기기·버전에서 스피커로 되돌아간다는 보고가 있어, 실기기에서 재현되면 `.defaultToSpeaker` 를 빼고 «이어폰 없을 때만 `overrideOutputAudioPort(.speaker)`» 로 바꾼다.
- 엔진 정지는 스트림 onTermination(effect 취소 시)과 `stopCapture`(코디네이터) 양쪽에서 보장 — 둘 다 멱등. 진행 중이던 세션·답변 기록도 이때 폐기(파일 삭제)된다.
- 백그라운드 동결도 이 계약을 그대로 쓴다(계약 무변경, 2026-08-08) — `finishSessionAudioRecording()` 이 반환한 구간을 세션 리듀서가 `RecordingAudioSegment` 로 풀어 `suspendRecording(쌍)` 에 넘기면 그 세그먼트에 실린다. 순서가 「마감 → 쌍 등록 → `stopCapture`」인 건 위 폐기 규칙 때문이다(정상 종료의 순서 계승) → [[interview#세션]].
- 파일 기록 2계열은 `TapFileRecorder`(같은 tap 콜백이 나눠 씀, AAC — iOS 는 mp3 인코딩 미지원)가 맡는다 — 세션 전구간(`startSessionAudioRecording`/`finishSessionAudioRecording→SessionAudioRecording?`, 파일 유지·[[interview#프리뷰]] 합성 입력)과 답변 구간(`startAnswerRecording`/`answerAudio→Data?`, 반환 후 파일 즉시 삭제·[[api#Interview]] 제출). `SessionAudioRecording.startedAtHostSeconds` 는 첫 버퍼 호스트시각 — 합성 오프셋 보정 기준. 캡처 미가동이면 둘 다 조용히 무시(nil).
- AI 발화 구간 무음(`setSessionAudioMuted(Bool)`, 2026-08-06)은 **세션 기록기에만** 건다 — 서버가 질문 TTS·마무리 멘트를 영상에 자체 합성하므로 `.playAndRecord` 스피커 에코까지 담으면 이중 음성이 된다. 무음은 버퍼 스킵이 아니라 **같은 길이의 zero-fill 버퍼 기록**이다(스킵하면 m4a 가 벽시계보다 짧아져 이후 오디오가 통째로 앞으로 밀리고 립싱크·startSec 정렬이 무너진다). 원본 버퍼는 뒤이어 감지기·탐침이 읽으므로 변조하지 않고 별도 캐시 버퍼(포맷은 `file.processingFormat`, 매번 명시 zero-fill)를 쓴다. 첫 버퍼 호스트시각 스탬프는 무음 중에도 찍는다 — 기준은 타임라인 연속성이지 소리 유무가 아니다. 답변 기록기는 answering 에만 돌아 무관하고, 토글 소유는 세션 리듀서다([[interview#세션]]). 길이 보존은 `TapFileRecorderTests` 가 유닛으로 고정한다(무음이 실제로 들리는지는 실기기 E2E 몫).
- 재생 계약(2026-08-02): `play`(base64 mp3 — 요약 질문·마무리 멘트) · `playStream(url:headers:)`(질문 chunked TTS — `InterviewAudioStream` 을 풀어 전달해 Speech→Interview Interface 의존을 만들지 않는다) · `stopPlayback`(멱등). 재생 주체는 `AudioPlaybackManager` 액터 — 소비 effect 가 취소돼도 재생은 지속(마무리 멘트 fire-and-forget 근거)하고, 정지는 이탈·실패 전환의 코디네이터 호출뿐이다.

## 세션

`InterviewSessionFeature` — 단일 화면 턴 상태머신(asking/answering/processingAnswer/finalCountdown) + 세션 시계 1초 틱. 8:00 종료 해금(토스트+«면접 종료하기») → 11:50 빨간 초읽기 → 12:00 hard cap 종료(PRD §3.6). 질문 텍스트는 View 에 노출하지 않는다(TTS-only).

Figma «[Part2. 면접 녹화]» 435:8697: 683:9250(질문) · 683:9260(답변) · 683:9280(8:00 해금) · 683:9290(종료 확인) · 683:9302(최종 카운트다운). 옛 id(2529:6309·2537:9397·2537:9442·2537:9525·2555:7739 …)는 디자이너가 섹션을 다시 만들며 사라졌다 — 다른 문서·주석에 남은 옛 id 는 아직 안 훑었다(2026-08-18).

- phase 4종이 상태 칩 3종(PRD §3.5)에 대응한다 — «질문 듣는 중»/«답변 녹음 중»/«답변을 정리하고 있어요», finalCountdown 은 칩 없이 빨간 초읽기. «답변이 기록 됐어요» 토스트는 칩이 역할을 대체해 소멸했고, 남은 토스트는 exitUnlocked·timeExpired 2종뿐이다.
- 하단 미니 버튼은 8:00 해금 뒤 **둘**이 된다(2026-08-18 시안 반영 — Figma «Interview_InProgress_ExitButtonShown» 683:9280): «면접 종료하기»(위, 흰 채움) 와 «답변 완료하기»(아래, 그린)가 세로로 쌓인다. 해금 뒤에도 턴은 계속 넘어가고 종료 시점은 사용자가 고른다 — 12:00 상한까지 답변을 이어가도 된다. 답변 완료 칸은 `answering` 이 아닐 때도 자리를 지킨다(감추기만) — 빼면 위 버튼과 상태 칩이 턴마다 46 내려앉는다. **최종 카운트다운(11:50~)엔 버튼이 하나도 없다**(683:9302) — 남은 10초는 상한이 끝내니 고를 것이 없고, 종료 확인 모달을 띄우면 답하는 사이 HARD_CAP 이 떨어진다. 그때도 답변 완료 칸(34)은 자리로 남아 토스트가 시안만큼 내려온다. 2026-08-14 의 «해금 뒤 종료 버튼 하나» 는 이 시안으로 뒤집혔다.
- «답변 완료하기» 는 침묵 판정을 기다리지 않고 즉시 `processingAnswer` 로 확정하고 `submitAnswer` 를 보낸다(중복 제출 가드 `isSubmitting`, 2026-08-02 작업 C — 2초 mock 소멸). 응답 분기: `nextQuestion` → asking 복귀+재생 / `sessionEnded` → endType 별 `finished(RecordingRef?, InterviewVideoWrapUpSpan?)`(NORMAL·MANUAL·HARD_CAP)·`aborted`(BACK_EXIT)·`failed(.speechRecognition)`(STT_RESET).
- 종료 경로도 제출을 경유한다 — 마치기=MANUAL_END·12:00 상한=HARD_CAP(제출 완료까지 processingAnswer 로 대기, 제출 비행 중 상한 도달은 응답 수신 후 HARD_CAP 마감). **8분 전 이탈은 제출하지 않는다**(2026-08-09 설계 수정 — 아래 «중도 이탈»). 503 은 같은 제출을 1s·3s 백오프로 최대 2회 재시도, `SESSION_ALREADY_ENDED`(409)는 정상 종료로 수습한다(녹화가 있으면 정지·합성까지 태우고 `finished`).
- 질문 재생: 요약 질문(턴 0)은 READY 동봉 mp3(`play`), 이후 질문은 `questionAudioStream`→`playStream`(chunked). 재생 실패는 같은 questionId 1회 재시도(TTS 재생성) 후 네트워크 오버레이(아래). 시간 마킹(questionAudioStart/End·answerStart)은 세션 시계 **raw** 스냅샷 — 아래 0점 정렬로 녹화 타임라인과 같은 축이다(유효시간 아님).
- 실녹화 타임라인(2026-08-05 작업 B): `startRecording` 반환이 **세션 시계의 기준점**이다 — 반환값(그 세션의 누적 녹화초, 신규 시작이면 0)이 raw 축 시드고 시계·마이크 캡처·첫 질문 재생을 `recordingStarted` 가 한꺼번에 연다. onAppear 는 「프리뷰 확보 → 녹화 시작」을 **한 effect 로 순차** 잇는다(2026-08-08) — 재개 직행은 readiness 를 건너뛰어 프리뷰가 아직 없어서, 병렬로 두면 `startRecording` 이 «프리뷰 세션 없음» 으로 죽는다(`startPreview` 는 멱등이라 일반 진입은 즉시 반환). 시작 실패면 `hasRecording=false` 로 그대로 진행(영상 없는 리포트) — 세션 오디오도 열지 않는다. **세션 오디오(`startSessionAudioRecording`)는 별도 effect 로 떼지 않고 캡처 구독 effect 안에서 `startCapture()` 직후에 연다** — 캡처 엔진이 세팅하는 tap 포맷이 없으면 조용히 무시돼([[interview#음성 캡처]]) 마감이 늘 nil 이 되고 모든 세션이 영상 없는 리포트로 수렴한다(merge 는 두 Task 순서 미보장). 답변 구간 기록은 `questionPlaybackFinished`(answering 진입)가 연다.
- AI 발화 구간 세션 오디오 무음 토글은 3곳뿐이다(2026-08-06): `playCurrentQuestion` effect 시작부에서 mute(요약·스트림·재시도가 전부 지나는 단일 진입점) → `questionPlaybackFinished`(answering 진입)에서 unmute 후 답변 기록 시작(순서 보장 위해 같은 effect 안 순차) → `endSession` 의 마무리 멘트 재생 effect 시작부에서 다시 mute(해제 없음 — 곧 세션 오디오 마감이라 이후 기록 자체가 없다). 캡처 미가동·기록 미시작 호출은 조용히 무시된다. zero-fill 계약은 [[interview#음성 캡처]].
- 종료(NORMAL·MANUAL·HARD_CAP)는 녹화가 있으면 마무리 멘트를 **영상에 담고** 끝낸다 — 재생 완료까지 `isWrappingUp`(시계는 계측 전용, 해금·상한 로직 잠금)로 구간을 재고 「세션 오디오 마감 → `stopRecording`(정지+합성)」 후 `finished(ref, span)`. 녹화 없음·멘트 없음은 각각 fire-and-forget 재생·즉시 정지로 갈라진다. 정지·합성 실패는 ref nil 로 수렴(스펙 §⑥). BACK_EXIT·실패 경로의 폐기는 코디네이터 몫. **마이크는 마감 «직후·합성 앞»에 끊는다**(2026-08-07) — `stopCapture` 가 진행 중 세션 기록을 폐기하므로 마감과 merge 로 걸면 정상 종료마다 산출물이 날아가지만, 마감이 반환한 뒤엔 기록기 url 이 비어 있어 폐기가 아무것도 지우지 않는다. 같은 effect 안에서 순서를 세워 부르고 `.cancel(id:.micCapture)` 는 백스톱으로 남긴다. 합성 앞으로 당기는 이유는 합성이 **8~10초** 걸리기 때문 — 그동안 장치가 살아 있으면 «종료했는데 계속 보고·듣고 있다» 가 된다(카메라 쪽은 [[interview#프리뷰]]). 계측(`isWrappingUp`)·정지+합성(`isFinishing`) 두 구간 모두 종료·이탈 입력 4종(close/exit/finishInterview/leaveInterview)을 닫고 정지 자체도 1회로 막는다 — 이미 종료가 확정돼 재제출은 409 를 부르고, 그 경로가 두 번째 정지를 태우면 빈 결과가 진짜 ref 보다 먼저 도착해 코디네이터의 first-wins 가 영상을 버린다.
- «12분» 숫자는 어떤 화면·문구에도 노출하지 않는다(§3.10 — 사용자에겐 «약 10분»). 경과 시계는 10분을 넘어도 m:ss 로 계속 오른다.
- 좌상단은 **뒤로가기 `<`**(2026-08-03 시안 — 「Part2. 면접 녹화」 전 프레임 공통). DS `.hilitPresentedNavigationBar(surface: .dark, leading: .back)` — cover 라 present 판, 카메라 영상이 바닥이라 `.dark`(흰 글리프). 글리프만 X 에서 바뀌고 **배관은 그대로**다(아래 분기 유지). 브래킷(`CameraGuideFrame`)은 네비바 `safeAreaInset` **밖**(`.background`)에 둔다 — 안에 두면 콘텐츠가 44 밀려 327 정방형 중심이 22 내려간다. 같은 이유로 상단 칩·타이틀 offset 은 51 이 아니라 7(= Figma y94 − 바 하단 87).
- **중도 이탈은 세션을 끝내지 않는다**(2026-08-09 설계 수정): 8분 전 «그대로 나가기» 는 BACK_EXIT 를 제출하던 것을 그만두고 [[interview#세션]] **동결 경로를 그대로 탄다** — 세그먼트·held 를 남기고 홈으로 나가, 홈 «진행 중» 카드의 [이어서 진행] 이 `sessionId` 로 재개한다. 옛 동작은 그 자리에서 서버 세션을 닫아 `checkResume` 이 ENDED 를 돌려줬고, 재개가 원천 봉쇄됐다. 백그라운드 동결과 갈리는 지점은 하나뿐 — 시작 전(`!hasStarted`)에도 이탈은 반드시 이행한다(백그라운드는 그 자리를 지킨다). 확정 종료(진행분 리포트·차감)는 홈 [처음부터 시작] 의 `abandon(USER_EXIT)` 몫이라, **X = 잠시 나가기 / 홈 = 포기**로 역할이 갈린다 → [[app#Cross-feature Routing]]. ⚠️ 경고 모달 문구(«지금 나가면 방금 쓴 이용권 한장이 사라져요»)는 아직 옛 동작을 말한다 — 디자이너 확정 대기(사용자 결정 2026-08-09).
- 좌상단 뒤로가기는 8:00 전이면 중도 이탈 경고(«다음에 면접을 다시 진행할까요?», Figma modal 3907:890 — 아이콘 없음, «면접 계속하기»가 강조(검정) 쪽), 8:00 후면 종료 확인 모달(Figma 2555:7696)로 갈린다. 둘 다 destination 없이 Bool 플래그이고 같은 모달 컴포넌트를 쓴다 — 뷰가 두 Bool 을 enum 하나로 접어 DS `.hilitModal(item:)` 로 표출한다(종료 확인 우선, 동시 true 방어). 8:00 해금 틱이 열려 있던 경고를 닫아 «경고를 띄운 채 해금» 레이스를 막는다.
- `aborted` 는 기록 폐기가 아니다 — 그때까지의 턴은 서버가 보존하고 이용권도 차감된다(PRD §3.7 D1). 클라는 이탈 신호만 올린다.
- 정지+합성 구간(`isFinishing`)은 `LoadingModal` 로 덮는다(2026-08-07) — 합성은 실기기에서 **8~10초** 걸리는데 그 대부분이 `AVAssetExportSession` 의 `.waiting`(자원 획득)이고 실제 전송은 1~3초다. 대기가 영상 길이와 무관한 고정 비용이라(37초·555초 세션 모두 같았다) 짧은 세션도 줄지 않고, 캡처세션·오디오엔진을 미리 정지시켜도 줄지 않아 AVFoundation 내부 비용으로 본다. 그 구간엔 입력이 이미 잠겨 있어(위 4종 차단) 아무것도 안 띄우면 «앱이 멈췄다» 로 읽힌다 — 표출 우선순위는 종료 확인·이탈 경고보다 앞이다(같은 `.hilitModal(item:)` enum). **녹화 없이 끝나는 두 경로**(멘트 fire-and-forget 종료 · 409 수습)도 합성이 없을 뿐 같은 플래그를 세운다(2026-08-14) — 그 뒤로도 코디네이터가 리포트 채점을 기다리는 동안 화면이 이 자리에 머물기 때문이다([[interview#코디네이터]]).
- 네트워크 실패는 화면을 갈아치우지 않는다(2026-08-06) — 세션이 소유한 `@Presents var failure`(kind: .network) 오버레이가 덮고 세션 State·녹화·마이크는 그대로 산다(영상에 공백 구간이 남는다 — 허용). 진입점 3곳(질문 재생 재시도 소진 · 제출 실패(409 제외) · 계약 위반 응답)은 재생·제출·토스트 effect 와 모달 2종을 닫고 오버레이만 세운다. 화면 교체(코디네이터)로 하면 세션이 폐기돼 «이어서 진행하기» 가 불가능해서다 → [[interview#실패]].
- 시간 축이 둘이다: `elapsedSeconds`(raw, 0점 = 녹화 시작 — 재개 세션은 누적 녹화초 시드에서 잇는다)는 오버레이 중에도 계속 오른다 — **시간 마킹**이 이 축이라 여기서 멈추면 서버의 영상 정렬이 깨진다. 반대로 백그라운드 동결에선 녹화 자체가 끊겨 이 축도 멈춘다(아래 «백그라운드 동결»). 해금·상한·랩업 판정과 상단 시간 칩은 `effectiveElapsedSeconds`(= elapsed − `suspendedSeconds`)를 쓴다 — 오버레이 tick 이 suspended 를 올려 «일시정지» 를 만든다(`isWrappingUp` 계측 전용 tick 과 같은 장치). 정지로 클라 상한이 서버와 어긋나면 서버의 HARD_CAP 통보를 따른다.
- 재개는 `pendingRetry` 가 보관한 **단계**를 재실행한다 — 2단계다: 질문 재생(phase 를 asking 으로 되돌리고 시작 마킹을 raw 축으로 다시 찍는다) · 제출. 제출은 실패한 `AnswerSubmission` **payload 째** 보관해 그대로 재전송한다: `answerAudio()` 는 1회 소모성(반환 후 파일 삭제)이라 재조회하면 오디오가 nil 로 씻긴다. 재실패는 오버레이 재표시(횟수 제한 없음 — 탈출구는 «중단하기»).
- 오버레이 «중단하기» 는 **답변 제출 없이** 이탈하되, 서버엔 `abandonSession(NETWORK_DISCONNECT)` 를 보낸다(2026-08-08) — BACK_EXIT 제출은 이용권 차감을 뜻해 화면 문구(«중단하기를 선택할 경우에, 이용권은 차감되지 않아요»)와 충돌하지만, 중단 API 는 제출이 아니라 그 문구를 서버에 반영하는 환급 경로다. 오프라인일 공산이 커 **3초 레이스**로 묶고 결과와 무관하게 `aborted` 로 나간다(서버 잔여 세션은 hold 만료 위임). 보관값도 결과와 무관하게 clear 한다 — 재개 재료가 없는 세션이라 남기면 홈이 죽은 세션을 계속 제안한다. **오버레이는 그대로 둔다** — 이탈이 확정될 때까지 최대 3초가 걸리는데 여기서 내리면 [중단하기]를 누른 사용자가 그동안 산 것처럼 보이는 세션 화면을 마주한다(입력은 잠겨 있어 더 어긋난다). 실제로 걷히는 건 `aborted` 를 받은 코디네이터의 teardown 이다 — cover 째 사라진다. 그 레이스 동안은 `isAbandoning` 이 입력·잔광을 전면 잠근다: 열어 두면 X→«이탈하기»(BACK_EXIT)·8분 후 «마치기»(MANUAL_END)가 **다시** 제출돼 계약이 깨지고 버린 세션의 영상이 업로드 큐로 샌다. 같은 플래그를 `reduceFailure` 맨 앞에도 둔다 — 오버레이가 남아 있으니 그 두 버튼도 계속 눌리고, [중단하기] 재탭은 abandon 재발사를 [이어서 진행하기]는 버린 세션의 재생·재제출을 부른다. 아래 `isInterrupted` 와 겸용하지 않는 건 복귀 판정이 그걸 «재개 후보» 로 읽어서다.
- **백그라운드 동결**(2026-08-08): 세션 View 가 `scenePhase == .background` 를 `view(.sceneBackgrounded)` 로 올리면(구현은 `InterviewSessionFeature+Interruption.swift`) 재생·제출·토스트·**시계**를 한꺼번에 취소하고 모달 2종을 닫은 뒤, 「세션 오디오 마감 → `suspendRecording(쌍)` → `stopCapture` → held 갱신」 **순서 계약**으로 세그먼트를 닫는다(이 넷만 한 `.run` 안에서 순차다). held 갱신은 `hasRecording` 일 때만이고(녹화 없는 세션은 0초 보관값을 건드리지 않는다) 누적초 + `processToken` 을 함께 찍는다. 여기선 **raw 축도 함께 멈춘다** — 합성본에 백그라운드 공백이 없으니 시간 마킹도 멈춰야 정렬이 산다(오버레이의 `suspendedSeconds` 장치와는 별개다 — 그쪽은 녹화가 계속 돈다). **마이크 effect 는 취소하지 않는다**: 취소가 스트림 종료→`stopCapture` 로 이어져 진행 중 세션 기록을 폐기하므로 마감과 merge 로 나란히 두면 순서 미보장이고, 마감이 지면 무음 세그먼트가 된다(전 세그먼트 무음이면 합성이 통째로 throw). 대신 같은 `.run` 안에서 마감 뒤에 `stopCapture` 를 부르고 그 종료가 캡처 effect 를 끝낸다. `isInterrupted` 는 `reduceView`·`reduceInner` **양쪽 첫 줄**에서 입력과 잔광(늦은 제출 응답·재생 완료)을 전면 잠근다. 순서 계약이 끝나면 그 `.run` 의 **맨 끝**에서 `delegate(.interrupted)` 를 올려 곧장 홈으로 나간다(2026-08-09 개정 — 복귀 판정을 기다렸다 닫으면 그 왕복 동안 동결 화면이 보인다). 통보가 맨 끝인 건 그걸 받은 상위가 cover 를 닫으며 이 effect 를 취소하기 때문 — 위로 올리면 세그먼트 마감·held 갱신이 중간에 잘린다 → [[interview#코디네이터]].
- 동결 예외 2곳 — 이미 종료가 확정된 구간이라 재개 대상이 아니다: `isFinishing`(정지+합성)은 무시하고 완주시키고(Live 가 `beginBackgroundTask` 로 감싼다 — [[interview#프리뷰]]), `isWrappingUp`(마무리 멘트 재생 중)은 **청취를 포기하고 그 자리에서 span 을 닫아 즉시 마감**한다. 백그라운드에선 재생이 죽어 완료 이벤트가 영영 안 와 세션이 랩업에 갇히기 때문이고, 서버 세션은 이미 끝났으므로(제출 응답이 종료를 확정했다) 복귀 체크가 다시 볼 일도 없다.
- **재개 진입 시드**(`State(sessionId:resume:)`): readiness 를 건너뛰어 요약 질문이 없다 — `summaryQuestion` 을 옵셔널로 내려 첫 재생부터 스트림이다. 시드는 `confirmResume` 의 최신 턴 질문 + held 의 **근사** 누적초고, raw 축 확정은 `startRecording` 반환(에셋 실측)이 한다 — 성공했을 때만 덮고, 실패하면 근사 시드를 지킨 채 진행한다(0 으로 되돌리지 않는다). 8:00 해금은 `== exitUnlockSeconds` 등호 tick 이라 시드가 경계를 넘겼으면 다시 오지 않는다: 시드·실측 **어느 쪽이 넘겨도** 토스트 없이 켜고(재개는 이미 안내를 본 사용자다), 한 번 켜지면 유지한다. 랩업·상한 판정은 기존 유효 축 코드 그대로라 자동으로 따라온다.
- asking→answering 은 재생 완료(questionPlaybackFinished)가 전환한다 — 배선 완료. 발화 감지·침묵 10초 확정·사고 5초는 작업 B 잔여. 랩업은 8:45 경과 시 `isWrapUp=true` 제출로 서버에 알린다(새 질문 금지는 서버 판단).
- 시계 상태머신·이탈은 `InterviewSessionFeatureTests`, 턴 루프·제출 분기는 `InterviewSessionSubmissionTests`, 녹화 배선(시작 실패 폴백·마무리 구간 계측)은 `InterviewSessionRecordingTests`, 종료 확정 후 잠금·순서는 `InterviewSessionFinishTests`, 네트워크 오버레이(시계 두 축·pendingRetry 재실행·제출 없는 중단 + abandon 발신)는 `InterviewSessionNetworkFailureTests`, 백그라운드 동결 순서·잠금과 재개 시드(시계 이음·해금·질문 출처 분기)는 `InterviewSessionBackgroundTests` 가 고정 (TestClock). 무음 토글 순서만 별도 파일 `InterviewSessionAudioMuteTests.swift` 로 뺐다 — 한 파일 1000행(SwiftLint file_length 에러) 한계고, 동결·재개도 같은 이유로 파일을 갈랐다.

## 실패

`InterviewFailureFeature` — 면접 중단 안내 공통 화면. kind 3종(speechRecognition·network·questionPrep)이 배지·문구·하단 버튼만 바꾸는 같은 레이아웃이라 리듀서는 kind 파라미터 하나뿐이다(Figma 2550:7504 · 2638:17018). 이용권 미차감 안내(서버 자동 환불 — [[interview#API]])는 공통.

- **표시 주체가 kind 별로 다르다**(2026-08-06): speechRecognition·questionPrep 은 코디네이터가 화면을 교체해 띄우는 터미널([[interview#코디네이터]]), network 는 세션이 `@Presents` 오버레이로 얹는 복구 지점([[interview#세션]]) — 한 리듀서가 두 부모를 섬긴다. delegate 는 `closeRequested`(X·«중단하기»·«처음으로» 공통)와 network 전용 `resumeRequested` 둘뿐.
- 하단 버튼: speechRecognition = «중단하기» 단일 / network = «이어서 진행하기»|«중단하기» 2분할(dark) / questionPrep = «처음으로». STT 의 재시작 버튼·delegate 는 2026-08-06 시안에서 소멸했다 — STT_RESET 은 서버가 세션을 무효화해 같은 sessionId 재진입이 거부되므로 지킬 수 없는 약속이었다(옛 «무효 세션 재진입» 제약도 이로써 소멸).
- 이용권 문구도 kind 별로 갈린다 — network 만 «중단하기를 선택할 경우에, …» 조건형이다(재개가 가능해 차감 여부가 선택에 달렸다). 오버레이 «중단하기» 가 BACK_EXIT 제출을 태우지 않는 근거가 이 문구고, 2026-08-08 부터는 같은 문구가 `abandon(NETWORK_DISCONNECT)`(환급) 발신의 근거이기도 하다 → [[interview#세션]].
- questionPrep 은 세션이 아니라 준비 화면의 폴링이 올린다([[interview#준비]]) — 질문 준비 최종 실패(서버 FAILED).
- 질문 준비 실패 화면(`Interview_QuestionPrepFailure`)은 Figma 시안 미출 — 레이아웃·배지를 network 실패에서 임시 재사용 중이라 시안 확정 시 교체한다.

## 업로드 큐

`InterviewVideoUploadQueue`(DomainInterview) 가 면접 영상을 화면·앱 수명과 무관하게 완주시킨다 — 정상 종료가 산출물을 접수하면(파일 소유권 이전) 코디네이터는 즉시 홈으로 가고 전송은 뒤에서 이어진다. 진행·성공·실패 UI 는 없고(조용한 업로드), 리포트 완료 표시·통지는 Part 3/홈 몫이다.

- `enqueue(sessionId·fileURL·wrapUp)` 는 파일을 `Application Support/InterviewUploads/<sessionId>.mp4` 로 **이동**(+백업 제외)하고 저널(JSON)에 적은 뒤 반환한다 — 네트워크가 없어 밀리초라 코디네이터가 홈 전환 전에 await 해도 사용자는 못 느낀다. tmp 를 쓰지 않는 이유는 OS 가 임의로 지우기 때문 — 재실행 재개가 전제다.
- 같은 sessionId 재접수는 무시한다(dedup) — 늦은 두 번째 `finished` 가 업로드를 재시작시키지 못하게([[interview#코디네이터]] first-wins 와 이중 방어). 접수 실패(파일 이동 불가)는 로그만 남기고 포기한다.
- 1회 시도 = 발급(`videoUploadURL`) → background PUT([[domain.map#네트워킹 인프라]] `BackgroundTransferClient`) → 완료 이벤트 → `completeVideoUpload` → 저널·파일 삭제. 발급·complete 는 앱 프로세스가 살아 있을 때(백그라운드 wake 포함)만 돌고, **PUT 만** 앱이 사라져도 시스템 데몬이 이어간다.
- 저널 단계는 2단(`completing`/`pending`) — PUT 완료 이벤트를 받으면 complete **전에** completing 으로 올려 기록한다. 그 틈에 죽어도 재개가 PUT 을 되풀이하지 않고 멱등한 complete 만 다시 친다. pending 재개는 발급부터라 만료 URL 이 자연 해소되고, PUT 덮어쓰기도 안전하다.
- 재시도는 «시도 실패 시 즉시 1회»(2026-08-05 의 1+1 정책 계승)뿐이고 소진되면 파킹한다. `resumePending()` 이 그 재시도권을 리셋하므로 실질 정책은 «실행 시점마다 1회» 다. 생성 후 **72시간**을 넘긴 항목은 resume 이 파일·저널째 폐기한다 — 영상 없는 리포트가 1급 폴백이라 무한 보관하지 않는다.
- 재개는 만료 폐기 직후 **저널에 대응 항목이 없는 mp4** 도 지운다 — 완주가 저널 제거와 파일 삭제 사이에서 끊기면 파일만 남아 영구 누수가 되기 때문. 저널을 읽은 **뒤**라야 안전하다(먼저 돌면 진행 중 산출물을 고아로 오인한다).
- `resumePending()` 호출부는 둘 — `AppFeature.onAppear`(앱 시작)와 `AppDelegate.handleEventsForBackgroundURLSession`(wake — completionHandler 는 전송 계층에 넘겨 이벤트 소진 시점에 불리게 한다). 강제 종료(스와이프)는 iOS 가 전송을 취소하는 플랫폼 제약이라, 저널 재개가 유일한 회복 수단이다.
- wake 는 이벤트 소진 직후 iOS 가 앱을 정지시켜 complete 를 자를 수 있다(저널만 `.completing` 으로 남고, 그 사이 서버가 영상 없이 리포트를 확정한다). 그래서 AppDelegate 가 재개를 `beginBackgroundTask` assertion 으로 감싸고, **`resumePending()` 은 시도가 잦아들 때까지 반환하지 않는 계약**을 진다 — 뿌리고 곧장 반환하면 감쌀 구간이 없어 assertion 이 헛돈다. 잦아듦의 정의는 «진행 중 시도 0 ∧ 예약된 즉시 재시도 0» — 시도는 어디서 왔든(재개발·스트림발·재시도발) 두 집합 중 하나를 지난다. 예약분을 안 세면 실패 시도의 마감(finishAttempt)이 재시도 Task 의 actor 진입 «전»에 잠잠함을 선언해, assertion 이 걷힌 뒤 재시도가 도는 구멍이 생긴다. 완료 이벤트가 그 판정 직후에 도착하면 여전히 잘릴 수 있고, 그건 다음 실행의 멱등 재시도 몫이다.
- 본체 actor 는 `static shared` 하나 — 저널·완료 이벤트 구독이 프로세스 전역 단일이어야 코디네이터(enqueue)·AppFeature·AppDelegate 가 같은 큐를 본다. 의존은 `@Dependency` 가 아니라 init 주입이라 `InterviewVideoUploadQueueTests` 가 스텁 한 벌(+스크래치 디렉토리 저널)로 계약을 고정한다. background URLSession 실물은 유닛 제외 — 실기기 E2E 몫이다.
- 설계 근거(결정표·에러 폴백표): [2026-08-06 스펙](../docs/superpowers/specs/2026-08-06-interview-exit-background-upload-design.md).
