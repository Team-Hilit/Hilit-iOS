# lat.md 검색 + 프로젝트 생성 단축 명령
# 사용: make lat q=profile   /   make lat-all   /   make lat-deps q=profile
#
# 검색은 ripgrep(rg) 이 있으면 rg, 없으면 grep 으로 자동 폴백.
# 속도를 위해 ripgrep 설치 권장: brew install ripgrep

RG := $(shell command -v rg 2>/dev/null)
ifeq ($(RG),)
  SEARCH = grep -rn --include='*.swift'
else
  SEARCH = rg --type swift -n
endif

.PHONY: device-qa generate install-snippets lat lat-all lat-deps lint lint-fix scaffold-core scaffold-domain scaffold-feature scaffold-shared test uitest

# 특정 도메인과 엮인 코드 전부 (위키링크 [[도메인 으로 검색 → delegate 의존도 잡힘)
lat:
	@$(SEARCH) '\[\[$(q)' Projects 2>/dev/null || echo "no @lat link to '$(q)'"

# 코드 전체의 @lat 라벨 목록
lat-all:
	@$(SEARCH) '@lat:' Projects 2>/dev/null

# 이 도메인을 depends-on 하는 코드 (= 바꾸면 영향받는 곳)
lat-deps:
	@$(SEARCH) 'depends-on.*$(q)' Projects 2>/dev/null || echo "nothing depends on '$(q)'"

# SwiftLint — 전 모듈 린트 (CI·터미널용. 빌드 페이즈와 같은 .swiftlint.yml 사용)
lint:
	@swiftlint lint --quiet

# 자동 수정 가능한 것 고치고 다시 린트
lint-fix:
	@swiftlint --fix && swiftlint lint --quiet

# Tuist 프로젝트 생성
generate:
	@tuist install && tuist generate

# 새 Feature 모듈 scaffold (예: make scaffold-feature name=Home)
# 파일 헤더의 author 는 git config user.name 에서 자동으로 채운다 (Tuist 매니페스트 실행 환경은
# Process/ProcessInfo.environment 를 못 읽어 stencil 기본값으로는 불가 — 그래서 여기서 셸로 주입).
# 생성 후 Project.swift 상단 ⚠️ 주석의 수동 작업 2단계를 완료하고 make generate 실행
scaffold-feature:
	@[ -n "$(name)" ] || (echo "❌ name 필수. 예: make scaffold-feature name=Home"; exit 1)
	@tuist scaffold Feature --name $(name) --author "$$(git config user.name)"
	@echo "✅ Feature$(name) 생성 완료. Projects/Feature/Feature$(name)/Project.swift 의 ⚠️ 주석을 확인하세요."

# 새 Domain 모듈 scaffold (예: make scaffold-domain name=User)
# 생성 후 Project.swift 상단 ⚠️ 주석의 수동 작업 2단계를 완료하고 make generate 실행
scaffold-domain:
	@[ -n "$(name)" ] || (echo "❌ name 필수. 예: make scaffold-domain name=User"; exit 1)
	@tuist scaffold Domain --name $(name) --author "$$(git config user.name)"
	@echo "✅ Domain$(name) 생성 완료. Projects/Domain/Domain$(name)/Project.swift 의 ⚠️ 주석을 확인하세요."

# 새 Core 모듈 scaffold (예: make scaffold-core name=Network)
# 생성 후 Project.swift 상단 ⚠️ 주석의 수동 작업 2단계를 완료하고 make generate 실행
scaffold-core:
	@[ -n "$(name)" ] || (echo "❌ name 필수. 예: make scaffold-core name=Network"; exit 1)
	@tuist scaffold Core --name $(name) --author "$$(git config user.name)"
	@echo "✅ Core$(name) 생성 완료. Projects/Core/Core$(name)/Project.swift 의 ⚠️ 주석을 확인하세요."

# 새 Shared 모듈 scaffold (예: make scaffold-shared name=DesignSystem)
# 생성 후 Project.swift 상단 ⚠️ 주석의 수동 작업 2단계를 완료하고 make generate 실행
scaffold-shared:
	@[ -n "$(name)" ] || (echo "❌ name 필수. 예: make scaffold-shared name=DesignSystem"; exit 1)
	@tuist scaffold Shared --name $(name) --author "$$(git config user.name)"
	@echo "✅ Shared$(name) 생성 완료. Projects/Shared/Shared$(name)/Project.swift 의 ⚠️ 주석을 확인하세요."

# Xcode 코드 스니펫 설치 — Tools/XcodeSnippets/ 의 팀 공용 스니펫을 Xcode 로 복사
# (tcapreview: TCA 기본 프리뷰 / tcapreviews: 시나리오·의존성 주입 프리뷰. Xcode 재시작 후 적용)
install-snippets:
	@mkdir -p ~/Library/Developer/Xcode/UserData/CodeSnippets
	@cp Tools/XcodeSnippets/*.codesnippet ~/Library/Developer/Xcode/UserData/CodeSnippets/
	@echo "✅ 스니펫 설치 완료. Xcode 를 재시작하면 tcapreview / tcapreviews 자동완성이 뜹니다."

# Feature 테스트 (예: make test scheme=FeatureHome [device='iPhone 15'])
#
# UDID 는 simctl 이 아니라 xcodebuild -showdestinations 에서 해석한다.
# simctl 목록엔 있어도 현재 Xcode 가 destination 으로 못 쓰는 런타임이 있어서
# (예: iPhone 16 이 iOS 18.0·26.1 둘 다 존재하는데 destination 은 26.1 만 유효)
# simctl 첫 UDID 를 집으면 "Unable to find a destination"(Error 70) 으로 죽는다.
# → 스킴이 실제 인식하는 destination 중 같은 이름의 최신 OS UDID 를 고른다.
device ?= iPhone 16
test:
	@[ -n "$(scheme)" ] || (echo "❌ scheme 필수. 예: make test scheme=FeatureHome"; exit 1)
	@dests=$$(xcodebuild -workspace Hilit.xcworkspace -scheme $(scheme) -showdestinations 2>/dev/null \
		| awk '/Ineligible destinations/{exit} /platform:iOS Simulator/ && /OS:/'); \
	if [ -z "$$dests" ]; then echo "❌ '$(scheme)' 스킴의 destination 조회 실패. Hilit.xcworkspace 가 없으면 make generate 먼저 실행하세요."; exit 1; fi; \
	id=$$(printf '%s\n' "$$dests" | grep -F "name:$(device) }" \
		| sed -E 's/.*id:([0-9A-Fa-f-]+),.*OS:([0-9.]+).*/\2 \1/' \
		| sort -t. -k1,1n -k2,2n | tail -1 | awk '{print $$2}'); \
	if [ -z "$$id" ]; then echo "❌ '$(device)' 는 '$(scheme)' 스킴의 destination 에 없음. 인식되는 시뮬레이터:"; printf '%s\n' "$$dests"; exit 1; fi; \
	xcodebuild -workspace Hilit.xcworkspace -scheme $(scheme) -destination "platform=iOS Simulator,id=$$id" test

# 실기기 QA 보조 (예: make device-qa cmd=force-kill [DEVICE=<udid|이름>])
# devicectl 로 실행·강제 종료·스크린샷·컨테이너 수집. 결과는 .device-qa/<시각>/. → docs/device-qa.md
device-qa:
	@Tools/DeviceQA/device-qa.sh $(cmd)

# 실기기 UI 테스트 (예: make uitest device='EunSeo iPhone') — 스킴 HilitUITests(Dev 계)
# 시뮬레이터로 돌리려면 device='iPhone 16' 처럼 시뮬레이터 이름을 준다. 실기기는 기기 잠금을 잡는다(반납: make device-qa cmd=unlock).
uitest:
	@[ -n "$(device)" ] || (echo "❌ device 필수. 예: make uitest device='EunSeo iPhone' (목록: xcrun devicectl list devices)"; exit 1)
	@if xcrun simctl list devices available | grep -qF "$(device) ("; then \
		dest="platform=iOS Simulator,name=$(device)"; \
	else \
		DEVICE="$(device)" Tools/DeviceQA/device-qa.sh lock || exit 1; \
		dest="platform=iOS,name=$(device)"; \
	fi; \
	xcodebuild -workspace Hilit.xcworkspace -scheme HilitUITests -destination "$$dest" -allowProvisioningUpdates test
