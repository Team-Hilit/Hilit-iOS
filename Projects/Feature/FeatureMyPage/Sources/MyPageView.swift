//
//  MyPageView.swift
//  FeatureMyPage
//
//  Created by 서정원 on 26/08/01.
//

import ComposableArchitecture
import SafariServices
import SharedDesignSystemInterface
import SwiftUI
import UniformTypeIdentifiers

// @ViewAction 매크로가 send(_:) 를 제공한다 — View 는 store.send(.view(...)) 대신 send(.onAppear) 로만 방출.
@ViewAction(for: MyPageFeature.self)
public struct MyPageView: View {
    @Bindable public var store: StoreOf<MyPageFeature>

    public init(store: StoreOf<MyPageFeature>) {
        self.store = store
    }

    public var body: some View {
        // 스크롤 판에 «보이는 높이» 를 최소값으로 물린다 — 내용이 짧으면 남는 자리를 Spacer 가 먹어
        // «회원탈퇴» 가 화면 바닥에 붙고(MyPage_Report_empty), 길면 Spacer 가 0 이라 목록 바로 아래에 온다(MyPage_Main).
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    MyPageProfileSection(
                        profile: store.profile,
                        onLogout: { send(.userTappedLogout) }
                    )
                    // 프로필 아래는 통째로 g50 판이다 — 내용이 짧아도 바닥까지 회색이 이어지도록 스크롤 배경도 같은 색.
                    VStack(spacing: 0) {
                        portfolioSection
                        reportSection
                        Spacer(minLength: 0)
                        withdrawButton
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color.GrayScale.g50)
                }
                .frame(minHeight: proxy.size.height)
                // 위로 당겨 바운스할 때 드러나는 자리 — 맨 위가 흰 프로필 판이라 그 위도 흰색이어야 한다.
                // 스크롤 판 배경(g50)은 그대로 두므로 아래쪽 바운스는 회색으로 남는다(내용 바닥과 같은 색).
                .background(alignment: .top) {
                    Color.BlackWhite.white
                        .frame(height: proxy.size.height)
                        .offset(y: -proxy.size.height)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background { Color.GrayScale.g50.ignoresSafeArea() }
        // 탭이 아니라 present 로 올라오는 한 장짜리 화면이다 (스택 밖 → presented 경로).
        .hilitPresentedNavigationBar(
            "마이페이지",
            background: .filled,
            onClose: { send(.userTappedClose) }
        )
        .hilitModal(item: store.presentedModal) { modal in
            MyPageModalCard(
                modal: modal,
                onCancel: { send(.userTappedModalCancel) },
                onConfirm: { send(.userTappedModalConfirm) }
            )
        }
        .alert($store.scope(state: \.alert, action: \.alert))
        // PDF 열람 — 발급받은 presigned URL 을 Safari 뷰로 연다. 앱을 벗어나지 않고, PDF 렌더링과
        // 닫기 버튼을 시스템이 맡는다(원격 URL 이라 로컬 파일이 필요한 QuickLook 은 못 쓴다).
        .sheet(item: $store.portfolioPreview) { preview in
            SafariView(url: preview.url)
                .ignoresSafeArea()
        }
        // 문서 피커는 이 화면 안에서 연다 — 업로드 진입 3곳(빈 판·«다시 올리기»·교체 확인)이 같은 자리로 모인다.
        .fileImporter(isPresented: $store.isFilePickerPresented, allowedContentTypes: [.pdf]) { result in
            if case let .success(url) = result { send(.fileSelected(url)) } else { send(.fileSelectionFailed) }
        }
        .onAppear { send(.onAppear) }
    }

    // MARK: - 내 포트폴리오

    private var portfolioSection: some View {
        VStack(alignment: .leading, spacing: .ds(.p10)) {
            sectionHeader("내 포트폴리오")
            portfolioContent
        }
        .padding(.horizontal, .ds(.p20))
        .padding(.top, .ds(.p20))
        .padding(.bottom, .ds(.p12))
    }

    @ViewBuilder
    private var portfolioContent: some View {
        switch store.portfolio {
        case .empty:
            VStack(spacing: .ds(.p10)) {
                Button {
                    send(.userTappedUploadPortfolio)
                } label: {
                    FileUpload(.before())
                }
                .buttonStyle(.plain)
                FileUpload(.empty(message: "아직 첨부된 포트폴리오가 없어요"))
            }

        case let .uploading(file, progress):
            FileUpload(
                .progressing(.init(name: file.name, statusText: "Processing..."), progress: progress),
                onCancel: { send(.userTappedCancelUpload) }
            )

        case let .uploaded(file):
            FileUpload(.completed(.init(name: file.name, statusText: "Completed!")))

        case let .registered(file):
            VStack(spacing: .ds(.p10)) {
                FileCard(
                    file.name,
                    date: file.date,
                    size: file.size,
                    onRemove: { send(.userTappedRemovePortfolio) }
                )
                // 카드 탭 = PDF 열람. Button 으로 감싸지 않는 건 카드 안의 X(onRemove)가 중첩 버튼에
                // 삼켜지기 때문이다 — 탭 제스처는 그 버튼을 그대로 통과시킨다.
                .contentShape(Rectangle())
                .onTapGesture { send(.userTappedPortfolioFile) }
                InfoField("포트폴리오는 한 달에 한 번 바꿀 수 있어요. 지워도 지난 면접 리포트는 그대로 남아요.")
            }

        case let .failed(file):
            VStack(spacing: .ds(.p10)) {
                failedCard(file)
                InfoField("파일을 확인하고 다시 올려주세요.\npdf · 20mb · 30쪽 이내", style: .error)
            }
        }
    }

    private func failedCard(_ file: MyPageFeature.PortfolioFile) -> some View {
        FileCard(file.name, note: "업로드 실패", noteTone: .error, showsTooltip: true) {
            Button {
                send(.userTappedUploadPortfolio)
            } label: {
                HStack(spacing: .ds(.p8)) {
                    Image.Undo.default
                    Text("다시 올리기")
                }
            }
            .buttonStyle(.mini(.gray, layout: .withIcon))
        }
        .overlay(alignment: .topLeading) {
            if store.isPortfolioTooltipPresented {
                // @ds(component): 툴팁 열기 훅 없음 — FileCard 의 안내 아이콘은 «그리기»만 하고 탭을 안 넘긴다.
                //                 지금은 상태로만 띄우고 말풍선 탭으로 닫는다
                // @ds(layout): x 89 · y -24 — 말풍선 꼬리(좌하단에서 40 안쪽)를 카드 안 안내 아이콘에 맞추는 값
                Button {
                    send(.userTappedPortfolioTooltip)
                } label: {
                    BubbleField("아직 다시 업로드할 수 있어요!", .mini(mood: .light))
                }
                .buttonStyle(.plain)
                .offset(x: 89, y: -24)
            }
        }
    }

    // MARK: - 내 면접 리포트

    private var reportSection: some View {
        VStack(alignment: .leading, spacing: .ds(.p10)) {
            sectionHeader("내 면접 리포트")
            if store.reports.isEmpty {
                FileUpload(.empty(message: "면접을 시작하고 리포트를 받아보세요!"))
            } else {
                // 줄끼리 간격 0 — 접힘 카드의 테두리가 서로 맞닿아 목록 선을 만든다(시안 그대로).
                VStack(spacing: 0) {
                    ForEach(store.reports) { report in
                        reportRow(report)
                    }
                }
            }
        }
        .padding(.horizontal, .ds(.p20))
        .padding(.vertical, .ds(.p12))
    }

    private func reportRow(_ report: MyPageFeature.Report) -> some View {
        let isExpanded = store.expandedReportIDs.contains(report.id)
        return VStack(spacing: 0) {
            Button {
                send(.userTappedReport(id: report.id))
            } label: {
                FoldableCard(
                    report.title,
                    date: report.date,
                    time: report.time,
                    note: report.note,
                    error: report.status,
                    isExpanded: isExpanded
                )
            }
            .buttonStyle(.plain)
            if isExpanded {
                FoldableCardDetail(
                    [
                        .init("직군 · 연차", report.jobLevel),
                        .init("포트폴리오", report.portfolioName),
                        .init("JD", report.jobDescription)
                    ],
                    leadingAction: report.canOpenReport
                        ? .init("리포트 보기") { send(.userTappedOpenReport(id: report.id)) }
                        : nil,
                    trailingAction: report.canRequestFeedback
                        ? .init("지인 피드백 받기") { send(.userTappedRequestFeedback(id: report.id)) }
                        : nil,
                    error: report.detailError
                )
            }
        }
    }

    // MARK: - 회원탈퇴

    private var withdrawButton: some View {
        Button("회원탈퇴") { send(.userTappedWithdraw) }
            .buttonStyle(.miniSub(.none))
    }

    // MARK: - 조각

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .dsTypography(.body6)
            .foregroundStyle(Color.GrayScale.g500)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// PDF 열람용 Safari 뷰. presigned URL 은 원격이라 로컬 파일이 필요한 QuickLook 을 못 쓰고,
/// `openURL` 로 넘기면 앱을 벗어난다 — 시트 안에서 PDF 렌더링·닫기를 시스템에 맡기는 자리다.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    // 시트가 URL 별로 다시 만들어진다(`sheet(item:)`) — 갱신할 상태가 없다.
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
