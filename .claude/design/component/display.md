# 표시 — 값을 받아 보여주기만 하는 컴포넌트

태그·말풍선·카드·머리글·강조 텍스트. 탭 액션을 내보내면 `button.md`, 값을 바인딩으로 되돌려주면 `input.md`, 화면 전환·진행 표시면 `navigation.md`.
**표는 이름 알파벳순으로 유지한다** — 새 행을 끝에 붙이지 말고 제자리에 끼워 넣는다(동시 추가 시 git 자동 병합).

| 컴포넌트 | Figma | API | 용도 |
|---|---|---|---|
| `BubbleField` | bubble-field 2000:7532 | `(_ message:, _ kind: .wide(tail: .none/.top/.bottom) / .mini(mood: .light/.dark))` | 말풍선 — `.wide` 폭 274·py12(꼬리 top 은 좌상단, bottom 은 우하단) / `.mini` 내용폭·py8·꼬리 좌하단. 꼬리 17×11, 붙는 변 모서리에서 40 안쪽(`BubbleField.tailInset` — 꼬리 끝을 트리거에 겨누라고 공개한다). 꼬리 없는 `.wide(tail: .none)`(기본)이 토스트 — 위치·해제 타이밍은 호출부 |
| `CameraGuideFrame` | camera-frame 435:821 | `(text: String? = nil, blendsColorBurn: Bool = false)` | 카메라 위 얼굴 맞춤 가이드 — 327 정방형. 네 모서리 L자 브래킷(팔 37.5 · 두께 5 — 좌상단만 g300, 나머지 g200) + 중앙 문구(`head4` g400, p24). **에셋 없이 코드 드로잉**이다(브래킷이 단순 선이라 크기별 재수출보다 싸다). Figma `showText` 축은 `text` 의 유무로 표현. `blendsColorBurn` 은 **기본 꺼짐** — 시안의 `mix-blend color-burn` 이 얹히는 카메라 프리뷰가 UIKit 레이어(`AVCaptureVideoPreviewLayer`)라 backdrop 으로 삼지 못해 새까매질 수 있다(실기기 확인 대기). 화면 안 위치는 호출부 몫 |
| `CountdownCard` | countdown-card 3165:14623 | `(title:subtitle:time:status: .active/.ended)` | 남은 시간 다크 카드 — b800 판 p12, 제목+쉐브론 / g700 1pt 선 / 스톱워치 24 + 보조 문구(#D2D6DE 80%) + 시간 `sub3`. 상태가 글자·아이콘 색을 함께 옮긴다(`.ended` g300 + disabled 아이콘). **탭 없음** — 목적지가 화면마다 달라 호출부가 `Button`으로 감싼다. 폭은 호출부 몫 |
| `FeedbackCard` | feedback-card 2101:8861 — max 439:10351 · 서술형 미평가 439:10352 | `(_ item:, evaluation:, highlight:, quote:, onEdit:)` | 지인 피드백 한 장 — 흰 판 + **비대칭 테두리**(왼쪽 6 `outline-mega`, 나머지 세 변 1.2 `outline-m`, 전부 g100) · px16/py12 · 줄 간격 6: «평가 항목(`body9` g400) / 마커 얹힌 평가 문장(`HighlightedText` blue 조합) / 인용 줄(`QuoteField(.gray)`) / 수정 아이콘 16». `quote` nil = 서술형 미평가(439:10352). 시안 backdrop blur 10 은 미반영(판이 불투명 흰색이라 차이가 없다 — `.hilitModal` blur 40 과 같은 판단). 폭은 호출부 몫 |
| `FileCard` | card-pdf 439:10334 (케이스 9종 …10342) | `(_ name:, date:, size:, note:, noteTone: .neutral/.error, showsTooltip:, tone: .green/.white, onRemove:) { accessory }` | 첨부 파일 한 줄 카드 — 흰 판 + g100 1.5(`outline-sb`) 사방 테두리 · p14 · gap12: «36 파일 아이콘 / 파일명(`body2` g700) + 메타 줄 / 삭제 x 16 / 버튼 슬롯». show 축은 전부 값의 유무 — **예외가 `noteTone`**(마스터 9케이스는 전부 g400 이고 색은 화면 인스턴스가 덮어쓰는데, 덮어쓰는 이유가 «진행이냐 오류냐» 라서 유무로 표현이 안 된다. 시안 근거 Part5 업로드 실패 439:13132·439:13299 = #FF5757). 메타는 날짜·용량 `body10` g400(둘 다 있으면 사이 1.2×10 구분선) + 서브텍스트 `body9`(`.neutral` g400 / `.error` e500) + 툴팁 아이콘(**아이콘만** — 툴팁 표출은 호출부). 오른쪽 슬롯엔 `.mini(.gray, layout: .withIcon)`. `HomeModal` port 케이스의 `content` 에 얹히는 카드가 이것 |
| `FileUpload` | file-upload — before 435:1371 · empty 435:1369 · progressing 435:1378 · completed 435:1385 | `(_ status:, onCancel:, onAction:)` · `Status` 4종(`.before(title:guidance:)` 는 업로드 규격 문구가 기본값 — `.before()` 로 쓴다) · `Item(name:statusText:actionTitle:)` | 포트폴리오 첨부 판 — 한 컴포넌트가 업로드 전/후를 다 그리고 판 생김새가 상태마다 통째로 바뀐다. `.before` g50 판 + 1pt g100 테두리 + 44 업로드 원(h150) · `.empty` 흰 판 + g200 **점선** · `.progressing`/`.completed` 파일 행(테두리는 위·좌·우 세 변만 1.5) + 4pt 진행 바(g200 트랙 위 그린 / 꽉 찬 그린). **탭 없음** — `.before` 를 눌러 파일 선택기를 여는 건 호출부가 감싼다. 파일 행은 Figma 에서 `card-pdf` 인스턴스지만 `FileCard` 와 합치지 않기로 결정 — 테두리 3변(진행 바가 아래를 잇는다) vs 4변, 상태 문구 vs 날짜·용량 메타로 구조가 달라 조립하면 `FileCard` 에 단일 소비자 옵션이 열린다. 시안이 행 모양을 바꾸면 두 파일 동시 수정 |
| `FoldableCard` · `FoldableCardDetail` | card — folded 439:10343 · detail 439:10347 | `FoldableCard(_ title:, date:, time:, note:, error:, isExpanded:)` · `FoldableCardDetail(_ rows: [Row], leadingAction:, trailingAction:, error:)` | 접힌 요약 + 펼친 상세. folded = 흰 판 + g100 1.5 사방 · p14 · gap12 «제목 + (날짜·시각 + 메모 `TagLabel`) / 빨간 상태 태그 / 쉐브론 16». detail = **g100 판** · p14 · gap12 «라벨 열 70 고정 + 값 3줄 / 등폭 mini 2개(왼 `.filled` · 오른 `.black`) / 폭 100% 오류 띠». **탭 없음** — 펼침·이동 중 무엇이 걸리는지 화면마다 달라 호출부가 통째로 감싼다. detail 은 folded 바로 아래 붙는 전제라 테두리를 그리지 않는다 |
| `HighlightedText` | highlighted-text | `(_ text:, typography:, alignment:, plainForeground:)` + 체인 `.hilight(_:)`·`.hilightColor(_:)`·`.hilightFill(_:)`·`.hilightIcon(_:)`·`.hilightColors(foreground:background:)` | 형광펜 마커. **문장 전체를 넘기고 `.hilight("부분")`** — 미지정 시 전체 강조. `hilightColor` 6종(green/black/gray/blue/red/none)은 글자색+배경색 한 쌍. `hilightFill` 3종(full/midlined/underlined), 띠 두께는 `typography` 파생(≥20pt 12, 아니면 8). `Text` 확장은 불가 — 내부 문자열을 못 꺼낸다. `alignment` 는 넘친 줄을 **줄마다** 미는 것이라 호출부가 폭을 줘야 보인다. **여러 구간·긴 구간·구간별 탭은 이 컴포넌트가 아니다** — 전제(강조 하나 + 짧은 구절)가 다 깨진다. 그런 본문은 `AttributedString` 으로 직접 그린다(마커가 평평한 사각이 되므로 다른 물건) |
| `.hilitBottomSheet` | 477:6341 (전문 시트 — 폭 꽉·모서리 0·머리 그래버) · 딤 «hilit opacity/dark/65%» | 모디파이어 — `(isPresented:, detents:, surface: .white, showsGrabber: true, onDismiss:) { 본문 }` / `(item:, …) { sheet in switch … }` | 바텀시트 표출 — **시스템 `.sheet` 를 쓰지 않는다**(iOS 26 이 부분 높이 시트를 가장자리에서 띄워 그려 시안의 «폭 꽉·모서리 0» 판이 다른 물건이 됐다 — 디자인 반려, 이슈 #72). **DS 가 시트 크롬을 갖는다** — 딤(`HilitDim.sheet` — 블랙 **65%**, 모달 60% 와 값이 다르다)·자리·드래그·그래버·폭·모서리 0 이 여기 몫이고 호출부는 판 색(`surface`)과 본문만 준다(예전의 «껍데기만» 계약은 시트 룩이 화면마다 갈라져 접었다). `detents` 는 화면 높이 대비 비율의 **오름차순** 배열(`[662.0/812.0, 1]`) — 가장 작은 자리로 열리고 그래버를 끌어 나머지를 오간다. 원소 하나면 고정 높이. 착지·닫기 판정은 `HilitBottomSheetMotion`(임계 60pt + 관성 10%), 판은 아래로 끌면 **높이 유지한 채 offset**(줄이면 본문이 다시 흘러 덜컹거린다) 위로 끌면 자란다. 표출 층·제약은 `.hilitModal` 과 같다(아래 «표출 층» — cover, 화면당 하나). **값 기반** — 스스로 닫지 않고 사용자가 내린 것(딤 탭·아래로 끌기)만 `onDismiss` 로 되돌린다. 시트 2개↑ 화면은 `item:` 에 enum 하나. 사용처 AuthTerms 전문 시트 |
| `HilitDivider` | divider 435:828 | `()` | 구분선 한 줄 — 1pt g800, **다크 판 전제**(흰 판 위에서는 실선처럼 무겁다. 밝은 판의 선은 이 토큰이 아니다 — `CountdownCard` 의 b800 판 안 선은 g700). 라이트 변형이 필요해지면 축을 열기 전에 디자이너 확인. 이름의 `Hilit` 은 SwiftUI `Divider` 와의 충돌 회피(`HilitTextField` 와 같은 이유). 폭은 호출부 몫 |
| `.hilitModal` | modal 2302:6080 (딤) | 모디파이어 — `(isPresented:) { 카드 }` / `(item:) { modal in switch … }` | 모달의 **오버레이 층** — 카드와의 분담·레시피는 아래 «모달 — 두 층 조립». 딤(`HilitDim.modal` — 블랙 60% 실측. 대응 색 토큰이 없어 리터럴은 `HilitDim` 한 곳이지만 **시트 딤 65% 와는 별개 상수다**) 위 중앙 카드 + 좌우 px24(시안 327 = 375−48) + opacity 0.2 전환. **값 기반·읽기 전용** — 스스로 닫지 않는다(닫힘은 카드 버튼이 리듀서 액션으로), 딤 탭 dismiss 없음. 모달 2개↑ 화면은 `item:` 에 enum 하나 — 동시 표출을 타입으로 차단(InterviewSession). 시안 backdrop blur 40 미포함 — 필요하면 호출부가 배경 블러로 근사(전환도 호출부가 몬다 — 모달 페이드는 cover 안쪽이라 배경까지 끌고 오지 않는다) |
| `HomeModal` | home modal 435:1565 — opp 439:10408 · port 439:10409 | `(_ title:, subTitle:, icon:, info:) { content }` | 홈 모달 카드 — 흰 판 p24 **네 변** · 세로 리듬 12, **버튼 슬롯 없음**. 텍스트 순서가 `Modal` 과 반대다(**서브타이틀이 타이틀 위**) — 순서 축·버튼 유무 축을 새로 만들지 않으려고 별 타입으로 뒀다. 타이틀 `sub4` b800(`Modal` 은 레거시 변수 탓에 g900). `content` 는 port 케이스의 파일 카드 자리 — `FileCard` 를 넣는다. 폭·딤 배경·표시 전환은 `.hilitModal` 몫 |
| `LoadingModal` | modal/loading 435:1543 (인스턴스 439:10407) | `()` | 로딩 모달 카드 — 170 정사각 흰 판 가운데 74 스피너 링(b800 링 위 g500 호 0.31 바퀴, 두께 10, 1초 회전). **회전은 시안에 없다** — 정지 이미지로는 로딩으로 안 읽혀 코드가 준다. 텍스트·취소 슬롯 없음(문구가 필요해지면 시안을 먼저 받는다). **`.hilitButtonLoading` 과 별개** — 그쪽은 버튼 스코프 오버레이이고 시안에 없다 |
| `LoadingText` | loading/text 439:10225(롤링) · 439:10226(정착) | `(_ phrases: [String], activeIndex:, phase: .rolling/.settled)` | 로딩 문구 롤링 줄 — 문구를 가로 한 줄에 gap6 으로 늘어놓고(`sub7`) **활성 문구를 컨테이너 중앙에 맞춘다**(전용 `Layout` 이 한 패스에 배치 — 폭 실측 왕복 없음). 앞뒤 문구는 좌우로 넘쳐 잘린다. 비활성 g700 / 활성은 롤링 g600 · 정착 g50. **모션 스펙은 시안에 없다**(주석만 달려 있다) — 슬라이드 0.3 · 샤이닝 불투명도 왕복으로 근사했고 확정되면 재조정 |
| `MessageCard` | message-card — detail 435:1392 · mini 435:1401 | `(_ size: .detail(subtitle:title:contents:) / .mini(_), icon: Image = .HilitAnalyze.problem)` | AI 메시지 카드 — `.detail` b800 판 p12 «36 분석 아이콘 + 서브타이틀(`body9` g400)·타이틀(`body1` Bold 16) / 본문(`body7` g200)», `.mini` g800 판 «16 그린 스파클 + 본문 흰 글자». 두 판 색이 다른 게 시안이다. show 축은 값의 유무. `.detail` 아이콘은 instance-swap 슬롯(`hilit analyze` 3판), `.mini` 는 스파클로 닫혀 있다. 시안의 글자 열 270 고정은 유연 폭으로 옮겼다 |
| `Modal` | modal 2302:6080 | `(_ text:, subText:, icon:, info:, infoStyle: .gray/.error) { ButtonLarge(.modal, …) }` | 모달의 **카드 층**(확인·경고용 — 카드 선택 기준은 아래 «모달 — 두 층 조립») — 흰 판(px24·py40·gap20) + 하단 버튼 슬롯. Figma `showIcon`·`showSubText`·`showInfoField` 축은 **파라미터 nil** 로 표현. 아이콘은 열린 슬롯(모달마다 다른 일러스트가 실재 — `InfoField` 와 반대). 안내줄은 `InfoField` 인데 **판 색을 인스턴스가 바꾼다** — 경고 모달이 빨간 판을 쓰므로(Part5 업로드 불가 435:8895) `infoStyle` 로 열어뒀다(기본 `.gray`). 폭·딤 배경·표시 전환은 `.hilitModal` 몫(카드만 그린다) |
| `Parallelogram` | highlighted-text 배경 | `Shape` — `(slant:)` | 하이라이트 배경 Shape. 직접 쓰기보다 `HighlightedText` 우선 |
| `QuoteField` | quote-field — gray 435:1351 · greenOnDark 435:1354 · block 435:1357 | `(_ text:, style: .gray/.greenOnDark/.block, onEdit:)` | 작성된 코멘트 인용 줄 — 세로 바 + 한 줄(말줄임). **입력 위젯 아님**(커서·placeholder 상태 없음), 편집은 `.block` 의 «수정» 링크가 밖으로 넘긴다. `onEdit` 은 `.block` 전용(DEBUG assert) |
| `ReportCard` | report-card-open 439:9750 · report-card-close 439:9758 | `(date:, status: .open(title:) / .close)` | 리포트 목록 줄 — `.open` b800 판(px20/py24) «날짜 `body3` g500 / 타이틀 `sub4` 흰 / 오른쪽 그린 44 사각 안 24 화살표», `.close` 연한 그린 띠(p20) + 날짜 한 줄. 시안은 **독립 컴포넌트 둘**(variant set 아님)인데 같은 목록의 두 상태라 한 타입으로 합쳤다. **탭 없음**(목적지가 화면마다 다르다). 좌우 여백이 판 안(px20)에 있어 **화면 폭을 그대로 채우는** 줄이다 — 콘텐츠 열에 넣지 않는다. `.close` 판 색 #D2EFCC 는 대응 토큰이 없어 보류(`design/color.md` 승격 대기) |
| `SaveIndicator` | tag-with-icon 439:10567 | `(.saving / .saved)` | 자동 저장 상태 — 회색 DS 로딩 에셋(`Image.Loading.ingGray16`)을 무한 회전시켜 «저장 중 ...» / 그린 체크 «저장됨». 글자 `body5`(sb14) g500, 아이콘–글자 간격 8. 시스템 `ProgressView` 가 아닌 이유 — 시안이 도형·색을 지정했고 원본색 에셋이라 틴트가 안 통한다(사고 사례 1번). 미저장(표시 없음)은 호출부가 뷰를 숨긴다 |
| `SheetGrabber` | 바텀시트 머리 막대 — 477:6341 · «Home_Report_Sheet» · «Report_HighlightDetail_Sheet» 443:7324 | `()` | 바텀시트 손잡이 — g400 60×5 막대(모서리 0)를 높이 20 줄 가운데. 시스템 `presentationDragIndicator`(캡슐)와 규격이 달라 직접 그린다. **제스처 없음** — 끌어서 자리를 옮기는 판정은 시트 높이를 소유한 쪽에 있다. `.hilitBottomSheet` 는 이 줄을 스스로 얹고 제스처도 자기가 붙이므로 호출부는 손댈 게 없다. 직접 쓰는 곳은 화면 상주 시트(홈 리포트 판 — 드래그도 직접 붙인다)와 시스템 시트 위 그림용(리포트 하이라이트 상세 — 드래그는 OS 몫)이다. 줄 전체(h20)가 `contentShape` 라 막대 밖 빈자리까지 잡힌다 |
| `TagLabel` | tag 1941:7132 | `(_ text:, style: .grayGray, size: .compact)` | 소형 사각 태그 — «선택» 안내, 척도 극 라벨. 시트는 **padding 행 × 색조합 열** 두 축이라 파라미터도 둘 — `size` = `.compact`(`padding=0px` px4·`body6` m14) / `.regular`(`4px` px12·py4·`body5` sb14), `style` = 시트 칸의 «배경-글자» 축약을 푼 이름(`b-gr` → `.blackGreen`). **두 행에 다 있는 칸은 `blackGreen`·`grayGray` 뿐**이라 나머지는 한 행 전용 — 없는 조합은 `init` assert(`Style.sizes`·`Size.styles` 가 시트의 행/열). 색을 열린 `Color` 로 받던 옛 API 는 시안에 없는 조합을 만들 수 있어 닫았다(2026-07-31). `body6` 은 2026-07-30 에 `.body8` 오구현 정정한 값이다(사고 사례 10·13번). `dg-g`(`.darkGrayGray`)만 판이 한 단 어두운 g900 + 글자 g200 이다 — 다른 `dg-*` 처럼 g800 판 + g600 글자로 두면 글자가 판에 묻혀 안 읽힌다(2026-08-05 정정) |
| `TitleBox` | title-box 2094:7912 · title 2044:1856 | `(_ lines: [Line], tag:, tagStyle:, sub:, alignment:)` · `Line(_ text:, highlight:)` | 화면 머리글 — «뱃지 8 타이틀 4 서브» 수직 리듬. 타이틀 줄은 `head3` + 그린 마커(`HighlightedText`), 뱃지는 `TagLabel`, 서브는 `body4`. Figma `status` 축 = `alignment`, `light/dark` 축 = `.hilitSurface(_:)`(판은 화면 속성), `show*` 축 = 값의 유무. **`tagStyle` 은 파라미터** — 뱃지 팔레트를 정하는 건 판이 아니라 의미(필수 `.blackGreen` 기본 / 선택 `.grayGray`)다. `Line` 은 문자열 리터럴로도 쓴다(마커 없는 줄). **시안의 좌우 px20 은 뺐다** — 화면이 이미 콘텐츠 열에 20 을 줘서 겹친다. 폭은 호출부 몫 |
| `VideoOverlay` | video overlay 435:847(dark/open) · 435:845(dark/close) · 435:849(light/close) | `(_ variant:, height: CGFloat? = nil)` | 영상 위 아래쪽 그라디언트 스크림 — 위 투명, 아래 불투명한 세로 램프. Figma 축은 `mood`×`status` 인데 **light/open 은 실재하지 않아** 3조합만 enum 으로 닫았다(2축 곱으로 열면 없는 조합이 생긴다). 탭을 먹지 않는다(`allowsHitTesting(false)` 내장). 높이는 램프 «모양»과 분리 — 스톱이 비율이라 어느 높이에서도 시안 곡선이 유지되고, 기본값은 시안 높이. light/close 의 마지막 스톱 109.21% 는 SwiftUI 가 [0,1] 로 잘라 버리므로 **100% 지점 색을 보간**해 넣었다(alpha ≈ 0.907) |

## 모달 — 두 층 조립

모달은 항상 **오버레이 × 카드** 두 층이다. 외우는 건 한 문장 — **카드는 스스로 못 뜨고, 오버레이는 스스로 안 닫힌다.**

| 층 | 담당 | 담당 아닌 것 |
|---|---|---|
| `.hilitModal` (모디파이어) | 딤(블랙 60%)·중앙 배치·표시 전환·좌우 여백 24 | 카드 생김새 — 아무 뷰나 받는다 |
| `Modal` / `HomeModal` / `LoadingModal` (View) | 흰 판·내용·버튼 슬롯 | 폭·딤·표시/닫힘 — 단독으로 화면에 놓지 않는다 |

**표출 층 — 네비바까지 덮는다.** `.hilitModal`·`.hilitBottomSheet` 는 `fullScreenCover`(+ `.presentationBackground(.clear)`) 로 뜬다. 네비바는 시스템 UIKit 바라 뷰 안쪽 `overlay` 로는 딤이 그 밑에 깔려 X 만 환하게 남기 때문 — 시스템 alert 이 바를 덮는 것과 같은 층을 쓴다. 따라오는 규칙 둘:

- **한 화면에 두 번 붙이지 않는다** — 모달·시트를 섞어 두 번 붙여도 마찬가지로 둘째 cover 가 조용히 무시된다. 2개↑ 는 `item:` 에 enum 하나 (Bool 두 개 금지가 규약에서 **제약**으로 승격).
- **앱 루트는 `.hilitModalOverlay`** — 전역 로딩 전용 overlay 변형. 루트는 NavigationStack 밖이라 overlay 로도 네비바 위에 깔리고, 루트가 cover 를 쓰면 화면 모달과 presentation 자리를 다툰다. 루트 뷰에 얹으면 cover 아래로 가려지므로 전역 로딩은 최상단 별도 창(`GlobalLoadingWindow`)의 루트에 얹는다.

**모달은 닫힘 전환이 즉시다**(표출만 페이드 0.2) — cover 해제에는 전환을 태울 자리가 없다. 시트는 판이 먼저 내려간 **뒤**에 `onDismiss` 를 부르는 식으로 그 자리를 만들어 뒀다(슬라이드 0.3).

**카드 고르기**:

| 상황 | 카드 |
|---|---|
| 확인·경고 팝업 — 버튼으로 답을 받는다 | `Modal` (버튼 슬롯 = `ButtonLarge(.modal, …)` 단일/2버튼) |
| 홈 안내 — 버튼 없음, 서브타이틀이 타이틀 **위**, 파일 카드 슬롯 | `HomeModal` |
| 처리 중 — 화면 전체 잠금 | `LoadingModal()` (인자 없음) |

> **API 대기에는 직접 띄우지 않는다.** 모든 HTTP in-flight 는 `AppView` 가 이걸로 이미 덮는다(`NetworkActivity`) — 화면이 또 띄우면 두 겹이 되고, 화면별 스피너를 손으로 다는 것도 같은 중복이다. 화면이 자기 대기 UI(진행 카드·프리로드 체크리스트)를 그려야 하는 엔드포인트만 Domain liveValue 에서 `GlobalLoadingSuppression.run` 으로 전역 표출을 끈다. 직접 쓰는 건 네트워크가 아닌 처리(로컬 인코딩 등)뿐 → `lat.md/domain.map.md` «네트워킹 인프라»

**표준 레시피** (TCA):

```swift
// 모달 1개 — Bool
.hilitModal(isPresented: store.isExitConfirmPresented) {
    Modal("정말 나가시겠어요?") {
        ButtonLarge(.modal, tone: .twoColor) {
            Button("취소") { send(.userTappedCancelExit) }
        } trailing: {
            Button("나가기") { send(.userTappedConfirmExit) }
        }
    }
}

// 모달 2개↑ — enum 하나로 동시 표출을 타입으로 차단 (Bool 여러 개 금지)
.hilitModal(item: store.presentedModal) { modal in
    switch modal {
    case .exitConfirm: Modal("면접을 마칠까요?") { … }
    case .loading: LoadingModal()
    }
}
```

**닫힘은 항상 리듀서** — 오버레이는 값 기반·읽기 전용이라 버튼 클로저가 액션을 보내 상태를 내려야 닫힌다. 딤 탭 dismiss 없음(시안에 없음). SwiftUI `.sheet`/`.alert` 처럼 스스로 닫히길 기대하면 안 닫힌다 — 여기가 제일 자주 헷갈리는 지점.

같은 계약의 형제가 `.hilitBottomSheet` — 붙는 위치(바닥)와 닫는 길(딤 탭·아래로 끌기 → `onDismiss`)이 다르고, 판 색·본문만 호출부가 준다(모달과 달리 표준 «카드» 층이 없다 — 시트 크롬을 모디파이어가 통째로 갖는다).

## Figma 원본 불일치 — 디자이너 확인 대기

① `bubble-field` 의 dark 변형 이름이 `status=status5`(mini 여야 함)이고, `mood` 축은 mini 에만 실재한다(wide 는 light 뿐) — 시안대로 구현했다. ② `countdown-card` 제목 타이포가 상태마다 다르다(`active` sb16 / `end` sb18) — 실수로 보이지만 시안대로 구현했다. 보조 문구 색 변수명은 `Gray scale/300`(#D2D6DE)인데 팔레트의 `grayscale/gray-300` 은 #9DA0AC 다 — 팔레트 밖 값이라 파일 내부 private 상수로 보류. ③ `modal` 제목도 같은 레거시 컬렉션(`Gray scale/800` = #262A30)을 쓴다 — 이름상 800(#31333B)과 어긋나지만 값이 `g900`(#27282F)과 사실상 동일(Δ≤2)해서 이쪽은 토큰으로 흡수했다(② 는 팔레트 밖이라 보류, 이건 근사 범위 안). ④ `quote-field` 의 `.gray` 타이포·색이 **시안끼리 어긋난다** — 마스터(435:1351 의 텍스트 435:1353)·가이드 인스턴스(439:10618)·`feedback-card` 미평가판(510:8044)은 `body9_m_12` + `gray-400` 인데, `feedback-card` 평가판 인스턴스(510:8028, 텍스트 `I439:10351;2102:8878;1984:6997`)만 변수가 `body10_r_12` + `gray-500` 로 덮여 있다(그 노드조차 Figma CSS 출력은 m12/#8A8D9C 라 노드 하나 안에서 값이 갈린다). 다수(마스터 포함)를 따라 `body9`/`g400` 로 뒀다 — 통일 여부는 디자이너에게 넘겼다.

**`card` 세 변형 제목 색 모순** — 같은 «card» 컴포넌트인데 제목 색의 출처가 셋 다 다르다: `card-pdf`(`FileCard`)는 `grayscale/gray-700` 에 정상 바인딩 · folded(`FoldableCard`)는 변수 미바인딩 raw #3A3E47(팔레트 밖, g800·g700 사이) · detail(`FoldableCardDetail`) 값 열은 레거시 `gray/800` = #5D5C61(현행 팔레트에 대응 없음, 가장 가까운 g600 도 Δ22). 코드는 각각 g700 토큰 / 파일 내부 private 상수 2개로 시안대로 구현했고, 변수가 정리되면 팔레트 토큰으로 갈아탄다.
