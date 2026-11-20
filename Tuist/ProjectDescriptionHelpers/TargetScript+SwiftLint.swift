import ProjectDescription

public extension TargetScript {
    /// 빌드 시 SwiftLint 를 실행하는 공용 pre-action.
    ///
    /// 헬퍼(`Project.core/.client/.feature`)와 App `Project.swift` 가 각 타겟의 `scripts` 에 1번씩 꽂으면,
    /// 그 타겟 빌드 때 자기 모듈 디렉터리(`$SRCROOT`)를 루트 `.swiftlint.yml` 기준으로 린트한다.
    /// SwiftLint 미설치 환경에선 경고만 내고 빌드를 막지 않는다.
    ///
    /// 린트할 파일은 `find` 로 직접 고른다 — 경로에 한글이 있으면(Orca worktree `fix-160_녹화보관업로드` 등)
    /// `.swiftlint.yml` 의 `excluded` glob(`**/Tests` 등)이 안 맞아 테스트 코드까지 린트돼 빌드가 깨진다.
    static let swiftLint: TargetScript = .pre(
        script: #"""
        export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
        if ! command -v swiftlint >/dev/null; then
            echo "warning: SwiftLint 미설치 — brew install swiftlint"
            exit 0
        fi
        ROOT=$(git -C "$SRCROOT" rev-parse --show-toplevel 2>/dev/null || echo "$SRCROOT")
        set --
        while IFS= read -r f; do
            [ -n "$f" ] && set -- "$@" "$f"
        done <<EOF
        $(find "$SRCROOT" \( -name .build -o -name Derived -o -name Tests -o -name '*.docc' -o -name '*.generated.swift' \) -prune -o -name '*.swift' -print)
        EOF
        [ $# -eq 0 ] || swiftlint lint --quiet --config "$ROOT/.swiftlint.yml" "$@"
        """#,
        name: "SwiftLint",
        basedOnDependencyAnalysis: false
    )
}
