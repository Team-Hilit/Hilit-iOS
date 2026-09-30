//
//  OnboardingJobDescriptionUploadFeatureTests.swift
//  FeatureOnboardingTests
//
//  Created by EunSeo on 26/07/19.
//

import ComposableArchitecture
import DomainJDInterface
import Foundation
import Testing

@testable import FeatureOnboardingImplementation

@MainActor
struct OnboardingJobDescriptionUploadFeatureTests {
    private let link = "https://recruit.hilit.dev/jobs/123"

    @Test("계속하기를 누르면 링크를 검증하고, 성공하면 바로 다음 스텝으로 올린다")
    func continueValidatesThenAdvances() async {
        var initialState = OnboardingJobDescriptionUploadFeature.State()
        initialState.linkText = link
        let store = TestStore(initialState: initialState) {
            OnboardingJobDescriptionUploadFeature()
        } withDependencies: {
            $0.jdClient.validate = { [link] url in
                #expect(url == link)
                return JDValidation(valid: true, reason: nil, message: nil)
            }
        }

        #expect(store.state.isContinueEnabled)   // 형식 통과 링크면 검증 전에도 열린다.
        await store.send(.view(.userTappedContinue)) {
            $0.linkValidation = .loading
        }
        await store.receive(\.inner.linkValidated) {
            $0.linkValidation = .success
        }
        await store.receive(\.delegate.continueRequested, .link(link))
    }

    @Test("링크 입력만으로는 검증을 부르지 않고 이전 결과만 지운다")
    func typingDoesNotValidate() async {
        var initialState = OnboardingJobDescriptionUploadFeature.State()
        initialState.linkValidation = .failure(message: "x")
        // jdClient.validate 를 스텁하지 않는다 — 입력 중 호출이 일어나면 unimplemented 로 실패한다.
        let store = TestStore(initialState: initialState) {
            OnboardingJobDescriptionUploadFeature()
        }

        await store.send(\.view.binding.linkText, link) {
            $0.linkText = self.link
            $0.linkValidation = .idle
        }
        await store.finish()
    }

    @Test("링크를 비우면 대기 상태로 돌아간다")
    func emptyingLinkReturnsToIdle() async {
        var initialState = OnboardingJobDescriptionUploadFeature.State()
        initialState.linkText = link
        initialState.linkValidation = .failure(message: "x")
        let store = TestStore(initialState: initialState) {
            OnboardingJobDescriptionUploadFeature()
        }

        await store.send(\.view.binding.linkText, "") {
            $0.linkText = ""
            $0.linkValidation = .idle
        }
    }

    @Test("서버가 유효하지 않다고 응답하면 서버 메시지로 에러를 띄우고 머문다")
    func invalidLinkShowsServerMessage() async {
        var initialState = OnboardingJobDescriptionUploadFeature.State()
        initialState.linkText = link
        let store = TestStore(initialState: initialState) {
            OnboardingJobDescriptionUploadFeature()
        } withDependencies: {
            $0.jdClient.validate = { _ in
                JDValidation(valid: false, reason: "CRAWLING_FAILED", message: "크롤링에 실패했어요.")
            }
        }

        await store.send(.view(.userTappedContinue)) {
            $0.linkValidation = .loading
        }
        await store.receive(\.inner.linkValidated) {
            $0.linkValidation = .failure(message: "크롤링에 실패했어요.")
        }
        #expect(store.state.isContinueEnabled)   // 재탭이 곧 재시도.
    }

    @Test("검증 네트워크 오류는 기본 문구의 에러 상태가 된다")
    func validationNetworkFailureShowsFallbackMessage() async {
        var initialState = OnboardingJobDescriptionUploadFeature.State()
        initialState.linkText = link
        let store = TestStore(initialState: initialState) {
            OnboardingJobDescriptionUploadFeature()
        } withDependencies: {
            $0.jdClient.validate = { _ in throw NSError(domain: "test", code: -1) }
        }

        await store.send(.view(.userTappedContinue)) {
            $0.linkValidation = .loading
        }
        await store.receive(\.inner.linkValidationFailed) {
            $0.linkValidation = .failure(message: OnboardingJobDescriptionUploadFeature.fallbackErrorMessage)
        }
    }

    @Test("형식이 잘못된 링크는 계속하기가 꺼지고, 키보드 리턴은 서버 호출 없이 형식 에러를 띄운다")
    func invalidFormatFailsWithoutServerCall() async {
        let pastedBody = "백엔드 개발자 채용 — 3년 이상, 코틀린/스프링"
        var initialState = OnboardingJobDescriptionUploadFeature.State()
        initialState.linkText = pastedBody
        // jdClient.validate 를 스텁하지 않는다 — 서버 호출이 일어나면 unimplemented 로 테스트가 실패한다.
        let store = TestStore(initialState: initialState) {
            OnboardingJobDescriptionUploadFeature()
        }

        #expect(!store.state.isContinueEnabled)
        await store.send(.view(.userSubmittedLink)) {
            $0.linkValidation = .failure(message: OnboardingJobDescriptionUploadFeature.invalidFormatMessage)
        }
    }

    @Test("URL 형식 1차 검사 — http(s) 스킴 + 호스트만 통과한다")
    func linkFormatValidation() {
        #expect(OnboardingJobDescriptionUploadFeature.isValidLinkFormat("https://recruit.hilit.dev/jobs/123"))
        #expect(OnboardingJobDescriptionUploadFeature.isValidLinkFormat("http://43.202.34.84:8080/jd"))
        #expect(!OnboardingJobDescriptionUploadFeature.isValidLinkFormat("recruit.hilit.dev/jobs/123"))   // 스킴 없음
        #expect(!OnboardingJobDescriptionUploadFeature.isValidLinkFormat("ftp://recruit.hilit.dev"))      // 비 http(s)
        #expect(!OnboardingJobDescriptionUploadFeature.isValidLinkFormat("https://"))                     // 호스트 없음
        #expect(!OnboardingJobDescriptionUploadFeature.isValidLinkFormat("채용공고 본문 텍스트"))            // URL 아님
    }

    @Test("키보드 리턴은 계속하기와 같이 검증하고 다음 스텝으로 올린다")
    func submitValidatesAndAdvances() async {
        var initialState = OnboardingJobDescriptionUploadFeature.State()
        initialState.linkText = link
        let store = TestStore(initialState: initialState) {
            OnboardingJobDescriptionUploadFeature()
        } withDependencies: {
            $0.jdClient.validate = { _ in JDValidation(valid: true, reason: nil, message: nil) }
        }

        await store.send(.view(.userSubmittedLink)) {
            $0.linkValidation = .loading
        }
        await store.receive(\.inner.linkValidated) {
            $0.linkValidation = .success
        }
        await store.receive(\.delegate.continueRequested, .link(link))
    }

    @Test("링크 클리어는 입력과 검증 상태를 초기화한다")
    func clearLinkResetsValidation() async {
        var initialState = OnboardingJobDescriptionUploadFeature.State()
        initialState.linkText = link
        initialState.linkValidation = .failure(message: "x")
        let store = TestStore(initialState: initialState) {
            OnboardingJobDescriptionUploadFeature()
        }

        await store.send(.view(.userTappedClearLink)) {
            $0.linkText = ""
            $0.linkValidation = .idle
        }
    }

    @Test("이미 검증된 링크의 계속하기는 다시 부르지 않고 링크 페이로드를 올린다")
    func continueWithValidatedLinkEmitsLinkPayload() async {
        var initialState = OnboardingJobDescriptionUploadFeature.State()
        initialState.linkText = link
        initialState.linkValidation = .success
        let store = TestStore(initialState: initialState) {
            OnboardingJobDescriptionUploadFeature()
        }

        await store.send(.view(.userTappedContinue))
        await store.receive(\.delegate.continueRequested, .link(link))
    }

    @Test("빈 링크의 계속하기는 활성이고 스킵(nil)으로 올린다")
    func continueWithEmptyLinkSkips() async {
        let store = TestStore(initialState: OnboardingJobDescriptionUploadFeature.State()) {
            OnboardingJobDescriptionUploadFeature()
        }

        #expect(store.state.isContinueEnabled)
        await store.send(.view(.userTappedContinue))
        await store.receive(\.delegate.continueRequested, nil)
    }

    @Test("분석 중에는 계속하기가 비활성이고 탭도 무시된다")
    func continueIsDisabledWhileValidating() async {
        var initialState = OnboardingJobDescriptionUploadFeature.State()
        initialState.linkText = link
        initialState.linkValidation = .loading
        let store = TestStore(initialState: initialState) {
            OnboardingJobDescriptionUploadFeature()
        }

        #expect(!store.state.isContinueEnabled)
        // 비활성이라 눌릴 일이 없지만, 눌려도 중복 호출·delegate 방출 없이 무시된다.
        await store.send(.view(.userTappedContinue))
    }

    @Test("건너뛰기는 검증 중이어도 예약을 취소하고 스킵(nil)으로 올린다")
    func skipCancelsPendingValidation() async {
        var initialState = OnboardingJobDescriptionUploadFeature.State()
        initialState.linkText = link
        initialState.linkValidation = .loading
        let store = TestStore(initialState: initialState) {
            OnboardingJobDescriptionUploadFeature()
        }

        // 취소가 없으면 화면을 떠난 뒤 도착한 응답이 상태를 뒤늦게 뒤집는다(다음 진입에 남는 성공·에러 판).
        await store.send(.view(.userTappedSkip))
        await store.receive(\.delegate.continueRequested, nil)
        await store.finish()
    }

    @Test("유효 길이(200~3,000자) 직접 입력의 계속하기는 text 페이로드로 올린다")
    func continueWithDirectTextEmitsTextPayload() async {
        let body = String(repeating: "가", count: OnboardingJobDescriptionUploadFeature.State.minDirectTextLength)
        var initialState = OnboardingJobDescriptionUploadFeature.State()
        initialState.mode = .directText
        initialState.directText = "  \(body)  "   // 앞뒤 공백은 제거돼 올라간다.
        let store = TestStore(initialState: initialState) {
            OnboardingJobDescriptionUploadFeature()
        }

        await store.send(.view(.userTappedContinue))
        await store.receive(\.delegate.continueRequested, .text(body))
    }

    @Test("직접 입력이 비어 있으면 계속하기는 스킵(nil)으로 올린다")
    func continueWithEmptyDirectTextSkips() async {
        var initialState = OnboardingJobDescriptionUploadFeature.State()
        initialState.mode = .directText
        let store = TestStore(initialState: initialState) {
            OnboardingJobDescriptionUploadFeature()
        }

        await store.send(.view(.userTappedContinue))
        await store.receive(\.delegate.continueRequested, nil)
    }

    @Test("200자 미만 직접 입력의 계속하기는 무시된다 (다음 꺼짐)")
    func continueWithTooShortDirectTextIsIgnored() async {
        var initialState = OnboardingJobDescriptionUploadFeature.State()
        initialState.mode = .directText
        initialState.directText = String(repeating: "가", count: OnboardingJobDescriptionUploadFeature.State.minDirectTextLength - 1)
        let store = TestStore(initialState: initialState) {
            OnboardingJobDescriptionUploadFeature()
        }

        #expect(!store.state.isContinueEnabled)
        // 무효 입력이라 delegate 방출 없이 무시된다.
        await store.send(.view(.userTappedContinue))
    }

    @Test("직접 입력 길이별 검증 상태 — 활성/카운터/안내")
    func directTextValidationState() {
        let min = OnboardingJobDescriptionUploadFeature.State.minDirectTextLength
        let max = OnboardingJobDescriptionUploadFeature.State.maxDirectTextLength

        func state(_ length: Int) -> OnboardingJobDescriptionUploadFeature.State {
            var s = OnboardingJobDescriptionUploadFeature.State()
            s.mode = .directText
            s.directText = String(repeating: "가", count: length)
            return s
        }

        // 빈 입력 — 스킵 가능(활성), 안내 없음.
        let empty = state(0)
        #expect(empty.isContinueEnabled)
        #expect(empty.directTextValidationMessage == nil)

        // 200자 미만 — 비활성 + 짧음 안내.
        let short = state(min - 1)
        #expect(!short.isContinueEnabled)
        #expect(short.directTextValidationMessage == "공고 내용이 너무 짧아요. 200자 이상으로 넣어주세요.")

        // 유효(200자) — 활성 + 안내 없음.
        let valid = state(min)
        #expect(valid.isContinueEnabled)
        #expect(valid.isDirectTextValid)
        #expect(valid.directTextValidationMessage == nil)

        // 3,000자 초과 — 비활성 + 초과 안내 + 카운터 강조.
        let long = state(max + 1)
        #expect(!long.isContinueEnabled)
        #expect(long.isDirectTextOverLimit)
        #expect(long.directTextValidationMessage == "공고 내용은 3000자 미만으로 입력해주세요.")
    }

    @Test("탭 전환은 입력 모드를 바꾼다")
    func selectingModeSwitchesTab() async {
        let store = TestStore(initialState: OnboardingJobDescriptionUploadFeature.State()) {
            OnboardingJobDescriptionUploadFeature()
        }

        await store.send(.view(.userSelectedMode(.directText))) {
            $0.mode = .directText
        }
        await store.send(.view(.userSelectedMode(.link))) {
            $0.mode = .link
        }
    }

    @Test("검증 성공 후에는 직접 입력 탭 전환이 막힌다")
    func directTextTabIsDisabledAfterSuccess() async {
        var initialState = OnboardingJobDescriptionUploadFeature.State()
        initialState.linkText = link
        initialState.linkValidation = .success
        let store = TestStore(initialState: initialState) {
            OnboardingJobDescriptionUploadFeature()
        }

        await store.send(.view(.userSelectedMode(.directText)))
    }

    @Test("이전으로 탭은 delegate 로 코디네이터에 위임한다")
    func backDelegatesToCoordinator() async {
        let store = TestStore(initialState: OnboardingJobDescriptionUploadFeature.State()) {
            OnboardingJobDescriptionUploadFeature()
        }

        await store.send(.view(.userTappedBack))
        await store.receive(\.delegate.backRequested)
    }

    @Test("닫기 탭은 delegate 로 코디네이터에 위임한다")
    func closeDelegatesToCoordinator() async {
        let store = TestStore(initialState: OnboardingJobDescriptionUploadFeature.State()) {
            OnboardingJobDescriptionUploadFeature()
        }

        await store.send(.view(.userTappedClose))
        await store.receive(\.delegate.closeRequested)
    }

    @Test("스킵 툴팁은 onAppear 후 3초가 지나면 사라진다")
    func tooltipExpiresAfterDelay() async {
        let clock = TestClock()
        // jdClient 스텁 없음 — onAppear 툴팁 타이머는 서버 호출과 무관하다.
        let store = TestStore(initialState: OnboardingJobDescriptionUploadFeature.State()) {
            OnboardingJobDescriptionUploadFeature()
        } withDependencies: {
            $0.continuousClock = clock
        }

        #expect(store.state.showsSkipTooltip)   // 진입 직후(빈 링크 탭)엔 노출.
        await store.send(.view(.onAppear))
        await clock.advance(by: OnboardingJobDescriptionUploadFeature.tooltipDuration)
        await store.receive(\.inner.tooltipExpired) {
            $0.isTooltipExpired = true
        }
        #expect(!store.state.showsSkipTooltip)   // 3초 뒤 사라짐(입력이 비어 있어도).
    }
}
