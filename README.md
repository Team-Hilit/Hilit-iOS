# Hilit

> **면접의 모든 순간을 자신있게** — AI 면접관과 반복 연습하고, 지인의 다면 피드백으로 면접 소통 능력까지 키우는 iOS 앱

<p align="center">
  <img src="docs/images/hilit-intro.png" alt="Hilit 서비스 소개" width="480">
</p>

## 기술 스택

| 구분 | 기술 | 비고 |
|---|---|---|
| 언어 | Swift 6 | |
| UI | SwiftUI | |
| 아키텍처 | [TCA](https://github.com/pointfreeco/swift-composable-architecture) 1.26+ | 단방향 데이터 흐름, `@Dependency` 주입 |
| 모듈화 | [Tuist](https://tuist.io) 4.212 | TMA(The Modular Architecture) |
| 의존성 관리 | Swift Package Manager | `Tuist/Package.swift` |
| 소셜 로그인 | [Kakao iOS SDK](https://github.com/kakao/kakao-ios-sdk) 2.22+ | |
| 딥링크 | [ChottuLink iOS SDK](https://github.com/ConnectingDotsInfotech/chottulink-ios-sdk) 1.1.2+ | 유니버설 링크 수신 |
| 시스템 프레임워크 | AVFoundation · Speech · AuthenticationServices · PDFKit | 녹화·음성 인식·Apple 로그인·PDF |
| 테스트 | Swift Testing · XCTest | |
| 최소 지원 | iOS 17.0 | |

## 아키텍처

**SwiftUI + TCA** 를 **Tuist TMA** 로 모듈화한다. 앱을 4개 레이어로 나누고, Domain·Core·Shared 모듈은 `Interface`(계약) / `Implementation`(구현)으로 분리한다.

```
Projects/
├── App/      composition root — AppFeature(화면 코디네이터), 환경별 xcconfig (Dev/QA/Prod)
├── Feature/  화면 단위 모듈 (Reducer + View, Interface 없음)
├── Domain/   도메인 모델 + Repository(Client)
├── Core/     인프라 (네트워킹 등)
└── Shared/   DesignSystem (디자인 토큰 + 공용 컴포넌트)
```
