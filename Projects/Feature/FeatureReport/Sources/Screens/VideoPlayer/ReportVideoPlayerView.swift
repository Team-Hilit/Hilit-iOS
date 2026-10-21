//
//  ReportVideoPlayerView.swift
//  FeatureReport
//
//  Created by EunSeo on 26/07/25.
//

import AVFoundation
import ComposableArchitecture
import DomainInterviewReportInterface
import SharedDesignSystemInterface
import SwiftUI

// Figma «Report_VideoPlayer» https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS
//   443:7804 기본(딤 없음) · 443:7828 시트 진입 판(하단 «이전 화면으로 가기»)
//   443:7852 컨트롤 노출(딤 65% + video-control) · 443:7902 대본(긴 턴) · 443:7941 대본(짧은 턴)
// 하단 바(진행바·대본 버튼·«이전 화면으로 가기»)는 **붙박이**다 — 자동 숨김을 타는 건 딤과 재생 컨트롤뿐.
// 딤은 영상 위에만 얹힌다: 재생 컨트롤·하단 바를 딤보다 위에 쌓아 색이 변하지 않게 한다.
// 시스템 컨트롤을 쓰지 않고 AVPlayerLayer 를 직접 얹는다(Figma 컨트롤이 커스텀이라).
// AVPlayer 자체는 뷰 로컬이고, 재생 여부·시각은 리듀서가 소유한다 — 자세한 배경은 리듀서 주석.
@ViewAction(for: ReportVideoPlayerFeature.self)
public struct ReportVideoPlayerView: View {
    @Bindable public var store: StoreOf<ReportVideoPlayerFeature>
    @State private var player: AVPlayer?
    @State private var timeObserver: Any?

    public init(store: StoreOf<ReportVideoPlayerFeature>) {
        self.store = store
    }

    public var body: some View {
        ZStack {
            // 영상·딤은 화면 끝까지 번지고, 상단 X·하단 바는 세이프에어리어를 지킨다.
            Color.HilitBlack.b900.ignoresSafeArea()
            videoSurface.ignoresSafeArea()
            // 상단 X 를 밝은 영상 위에서도 읽히게 하는 스크림 — 항상 깐다 (Figma 443:7902 상단 그라데이션).
            topScrim
            // 붙박이 하단 바를 딤 없이도 읽히게 하는 스크림 — 딤보다 아래에 깔린다.
            if store.isBottomScrimVisible {
                bottomScrim
            }
            // 컨트롤을 띄우는 동안만 영상을 눌러 어둡게 한다.
            // **딤 위에 서는 것들** — 재생 컨트롤·하단 바는 이 아래가 아니라 위에 쌓는다(색이 변하지 않게).
            if store.isPlaybackControlVisible {
                // @ds(color): «hilit opacity/dark/65%» #000000 65% — 컨트롤 딤. 팔레트에 검정 토큰이 없다(BlackWhite 는 white 뿐)
                Color.black.opacity(Self.dimOpacity).ignoresSafeArea()
            }
            if store.isTranscriptOverlayVisible {
                TranscriptOverlay(
                    line: store.activeTranscriptLine,
                    currentSentenceIndex: store.transcriptPosition?.sentenceIndex ?? 0,
                    onHighlightTap: { cardIndex, spanIndex in
                        send(.userTappedHighlight(cardIndex: cardIndex, spanIndex: spanIndex))
                    }
                )
            }
            if let message = store.playbackFailureMessage {
                failure(message)
            }
            chrome
        }
        // 영상 풀블리드 위 투명 바(기본값) — X 는 플레이어를 닫고 리포트로 (리듀서 소유).
        // 바닥이 어두운 영상이라 `surface: .dark`(흰 X). 시안은 `cancel/24px/dark`(검정 X)를
        // 얹었지만 DS 는 «다크 바닥 + 검정 X» 를 표현 불가로 못박았고, 딤 65% 위에선 안 보인다.
        // 상세 시트가 올라와 있는 동안은 leading 슬롯을 비운다 — 모디파이어를 분기하지 않고
        // 값만 바꾼다(분기하면 뷰 identity 가 갈려 AVPlayer 를 쥔 `@State` 가 날아간다).
        .hilitNavigationBar(
            surface: .dark,
            leading: store.isCloseButtonVisible ? .close : .hidden,
            onClose: { send(.userTappedBack) }
        )
        .contentShape(Rectangle())
        .onTapGesture { send(.userTappedSurface) }
        .onAppear {
            send(.onAppear)
            startPlayback()
        }
        .onDisappear(perform: tearDownPlayback)
        .onChange(of: store.isPlaying) { _, isPlaying in
            isPlaying ? player?.play() : player?.pause()
        }
        // 토큰만 본다 — 같은 시각으로 다시 이동해도(리플레이) 놓치지 않는다.
        .onChange(of: store.seekToken) { _, _ in
            player?.seek(to: cmTime(store.seekTarget), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // 재생 재시도 — 실패한 AVPlayer 는 되살아나지 않아 통째로 새로 만든다(플레이어는 뷰 소유).
        .onChange(of: store.reloadToken) { _, _ in
            tearDownPlayback()
            player = nil
            startPlayback()
        }
        .sheet(item: $store.scope(state: \.highlightDetail, action: \.highlightDetail)) { store in
            ReportHighlightDetailView(store: store)
        }
    }

    // MARK: - 영상

    @ViewBuilder
    private var videoSurface: some View {
        if let player {
            VideoSurface(player: player)
        }
    }

    private func startPlayback() {
        guard player == nil else {
            // 화면으로 되돌아온 경우 — 상태가 재생 중이면 뷰의 플레이어도 다시 돌린다
            // (`onDisappear` 에서 멈췄는데 `isPlaying` 은 그대로라 onChange 가 안 걸린다).
            if store.isPlaying { player?.play() }
            return
        }
        let player = AVPlayer(url: store.videoURL)
        // 진입은 `startAt`, 재시도는 보고 있던 시각부터 — 둘 다 State 의 현재 시각이 답이다
        // (`currentTime` 초기값이 `startAt` 이고, 이후엔 재생 위치를 따라간다).
        if store.currentTime > 0 {
            player.seek(to: cmTime(store.currentTime))
        }
        // 0.2초 간격 — 진행바 칸 채움과 대본의 «현재 문장» 이 따라올 만큼만 촘촘하게.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: Self.timescale),
            queue: .main
        ) { time in
            // 재생 상황은 사용자 입력이 아니라 effect 결과라 inner 로 올린다 (D5).
            // 관찰은 0.2초마다 계속 오므로 «바뀐 것» 만 올린다.
            store.send(.inner(.timeUpdated(time.seconds)))

            if player.currentItem?.status == .failed {
                store.send(.inner(.playbackFailed(
                    message: ReportVideoPlayerFeature.playbackFailureMessage
                )))
                return
            }
            guard let duration = player.currentItem?.duration.seconds,
                  duration.isFinite, duration > 0
            else { return }
            if store.duration != duration {
                store.send(.inner(.durationLoaded(duration)))
            }
            if store.isPlaying, time.seconds >= duration {
                store.send(.inner(.playbackFinished))
            }
        }
        self.player = player
        player.play()
    }

    private func tearDownPlayback() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
    }

    private func cmTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: Self.timescale)
    }

    // MARK: - 상단·하단 고정 요소

    /// 상단 X 는 `.hilitNavigationBar` 가 얹는다 — 여기는 재생 컨트롤과 하단 바만 남는다.
    /// 재생 컨트롤은 화면이 아니라 «네비 바 아래 ~ 진행바 위» 사이 한가운데에 선다
    /// (Figma 443:7852 위아래 268 대칭) — 화면 가운데에 두면 하단 바 높이만큼 아래로 처진다.
    /// 빈 ZStack 으로 자리를 늘 잡아 둬야 컨트롤이 숨어도 하단 바가 바닥에 붙어 있다.
    private var chrome: some View {
        VStack(spacing: 0) {
            ZStack {
                if store.isPlaybackControlVisible {
                    playbackControls
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if store.isBottomBarVisible {
                bottomBar
            }
        }
    }

    /// DS `VideoOverlay(.darkClose)` 를 위아래로 뒤집어 상단에 깐다 — DS 램프는 «아래로 갈수록
    /// 진해지는» 방향뿐이라 방향만 화면이 뒤집는다(시안 443:7902 상단 판도 같은 컴포넌트의 뒤집기).
    /// 탭을 먹지 않아(컴포넌트 내장) 스크림 뒤 영상 탭이 살아 있다.
    private var topScrim: some View {
        VStack(spacing: 0) {
            VideoOverlay(.darkClose)
                .scaleEffect(x: 1, y: -1)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
    }

    /// DS `VideoOverlay(.darkClose)`(Figma «video overlay» 443:7830) — 시안 높이 그대로 쓴다.
    /// 탭을 먹지 않아(컴포넌트 내장) 스크림 뒤 영상 탭이 살아 있다.
    private var bottomScrim: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VideoOverlay(.darkClose)
        }
        .ignoresSafeArea()
    }

    /// Figma 443:7831 — 좌우 20, 진행바와 버튼 줄 사이 16, 대본 토글은 오른쪽 정렬.
    /// 버튼 줄 왼쪽 슬롯은 시트로 들어온 판에서만 «이전 화면으로 가기» 가 채운다(443:7843).
    /// **버튼 줄 높이는 44 로 고정**한다 — 대본 없는 보고서(토글 없음)에서 줄이 쪼그라들면
    /// 진행바가 내려앉아 하단 스크림 램프와 어긋난다. 대본 오버레이의 `bottomInset` 도 이 높이를 센다.
    private var bottomBar: some View {
        VStack(spacing: .ds(.p16)) {
            PlaybackProgressBar(store: store)
            HStack(spacing: 0) {
                if store.isReturnToPreviousVisible {
                    returnToPrevious
                }
                Spacer(minLength: 0)
                if store.hasTranscript {
                    transcriptToggle
                }
            }
            .frame(height: Self.controlSize)
        }
        .padding(.horizontal, .ds(.p20))
        .padding(.bottom, .ds(.p12))
    }

    /// 시안 443:7843 «button-medium» filled black — DS `.medium(.black)` 그대로.
    /// 상단 X 와 다르다 — X 는 리포트 메인까지, 이 버튼은 왔던 상세 시트까지 되돌린다.
    private var returnToPrevious: some View {
        Button("이전 화면으로 가기") { send(.userTappedReturnToPrevious) }
            .buttonStyle(.medium(.black))
    }

    /// 아이콘만 있는 정사각 버튼은 DS 버튼 카탈로그(large/medium/mini/sub/tag)에 없는 티어라
    /// 여기서 만든다 — 플레이어 컨트롤 전용이고 두 번째 사용처가 없다(승격 규칙 ③ 미충족).
    /// 대본을 켜면 같은 자리가 닫기 X 로 바뀐다 (Figma 443:7939 `cancel/20px/white`).
    // @ds(component): 44×44 g800 판(모서리 0) + 20pt 흰 글리프 — 아이콘 정사각 버튼 공용 컴포넌트 없음
    private var transcriptToggle: some View {
        Button {
            send(.userTappedTranscriptToggle)
        } label: {
            (store.isTranscriptVisible ? Image.Cancel.white20 : Image.Script.white20)
                .resizable()
                .scaledToFit()
                .frame(width: Self.toggleGlyphSize, height: Self.toggleGlyphSize)
                .frame(width: Self.controlSize, height: Self.controlSize)
                .background(Color.GrayScale.g800)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 재생 컨트롤

    /// DS `VideoControl`(Figma «video-control» 435:830) 그대로 — 화살표 44 · 간격 46 · 가운데 74 정사각.
    /// 좌우 화살표는 초 단위가 아니라 진행바 한 칸씩 움직인다(이동 단위는 리듀서 소유).
    private var playbackControls: some View {
        VideoControl(
            isPlaying: store.isPlaying,
            onSkipBackward: { send(.userTappedPreviousChunk) },
            onPlayPauseToggle: { send(.userTappedPlayPause) },
            onSkipForward: { send(.userTappedNextChunk) }
        )
    }

    // MARK: - 재생 실패

    /// 문구만 두면 막다른 화면이 된다(X 로 나가는 것 말고 할 게 없다) — 리포트 메인의
    /// «다시 시도하기» 와 같은 톤·같은 버튼으로 재생을 한 번 더 걸 길을 준다.
    private func failure(_ message: String) -> some View {
        VStack(spacing: .ds(.p12)) {
            Text(message)
                .dsTypography(.body3)
                .foregroundStyle(Color.GrayScale.g200)
                .multilineTextAlignment(.center)
            Button("다시 시도하기") { send(.userTappedPlaybackRetry) }
                .buttonStyle(.mini(.black))
        }
        .padding(.ds(.p20))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.HilitBlack.b900)
    }

    // MARK: - 수치 (Figma 스케일에 없는 컴포넌트 고유값은 여기 상수로 모은다)

    /// Figma 변수 «hilit opacity/dark/65%» — 딤 불투명도.
    private static let dimOpacity: Double = 0.65
    // @ds(layout): 44 — 대본 토글 슬롯 한 변. spacing 스케일(4~40)에 44 가 없다
    // (재생 컨트롤의 같은 수치는 DS `VideoControl` 이 소유한다)
    private static let controlSize: CGFloat = 44
    // @ds(icon): 20 — script/cancel 글리프. 에셋 원본 크기라 늘이지 않는다(image.md 크기 규칙)
    private static let toggleGlyphSize: CGFloat = 20
    private static let timescale: CMTimeScale = 600
}
